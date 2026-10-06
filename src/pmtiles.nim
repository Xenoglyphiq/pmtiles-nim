## PMTiles v3 reader, core layer: decode the header and directories, map
## z/x/y to tile ids, and find the directory entry for a tile.
##
## Implements the pmtiles spec (see `.spec/spec/SPEC.md`). Everything here works
## on in-memory bytes; reading archives from files, memory or HTTP is in
## `pmtiles/io`.
##
## Every public proc raises only `PMTilesError`. Overflow is checked by hand
## before any arithmetic on ids, offsets and lengths, so no `OverflowDefect` or
## `RangeDefect` can escape.

import std/options

export options

type
  ErrorKind* = enum
    ## Spec error kinds. `$kind` is the spec's canonical name.
    ekInvalidInput = "invalid_input"
    ekUnsupported = "unsupported"
    ekLimitExceeded = "limit_exceeded"
    ekIo = "io"                ## Only raised by `pmtiles/io`.

  PMTilesError* = object of CatchableError
    ## The only error raised by the spec operations.
    kind*: ErrorKind           ## Spec error kind.
    code*: string              ## Stable spec error code, e.g. `"pmtiles.bad_magic"`.
    offset*: Option[uint64]    ## Byte offset into the input, when known.

  Limits* = object
    ## Limits for the spec operations. Defaults match the spec.
    maxDirectoryEntries*: uint64 = 1_000_000      ## Entries in one directory.
    maxDirectoryBytes*: uint64 = 16 * 1024 * 1024 ## Bytes fetched for one directory.
    maxLeafDepth*: uint32 = 4                     ## Leaf pointers followed; the root is depth 0.
    maxMetadataBytes*: uint64 = 16 * 1024 * 1024  ## Bytes fetched for the metadata.

  CompressionKind* = enum
    ## Spec enum `Compression`. `ckUnknownValue` holds raw values outside the
    ## spec's table; the raw byte is kept in `Compression.raw`.
    ckUnknown = "unknown"      ## Raw 0: the archive says the compression is unknown.
    ckNone = "none"
    ckGzip = "gzip"
    ckBrotli = "brotli"
    ckZstd = "zstd"
    ckUnknownValue = "unknown_value"

  Compression* = object
    ## Open enum `Compression`: a known kind, or `ckUnknownValue` with the raw byte.
    kind*: CompressionKind
    raw*: uint8

  TileTypeKind* = enum
    ## Spec enum `TileType`. `ttUnknownValue` holds raw values outside the
    ## spec's table; the raw byte is kept in `TileType.raw`.
    ttUnknown = "unknown"
    ttMvt = "mvt"
    ttPng = "png"
    ttJpeg = "jpeg"
    ttWebp = "webp"
    ttAvif = "avif"
    ttUnknownValue = "unknown_value"

  TileType* = object
    ## Open enum `TileType`: a known kind, or `ttUnknownValue` with the raw byte.
    kind*: TileTypeKind
    raw*: uint8

  BBox* = object
    ## Bounds in WGS84 degrees.
    minLon*, minLat*, maxLon*, maxLat*: float64

  LonLat* = object
    ## A WGS84 coordinate in degrees, `(lon, lat)`.
    lon*, lat*: float64

  Header* = object
    ## The fixed 127-byte archive header (spec §2). Offsets and lengths are in bytes.
    specVersion*: uint8
    rootDirectoryOffset*, rootDirectoryLength*: uint64
    metadataOffset*, metadataLength*: uint64
    leafDirectoriesOffset*, leafDirectoriesLength*: uint64
    tileDataOffset*, tileDataLength*: uint64
    addressedTilesCount*: Option[uint64]  ## Absent when the archive stores 0 (unknown).
    tileEntriesCount*: Option[uint64]     ## Absent when the archive stores 0.
    tileContentsCount*: Option[uint64]    ## Absent when the archive stores 0.
    clustered*: bool
    internalCompression*: Compression
    tileCompression*: Compression
    tileType*: TileType
    minZoom*, maxZoom*: uint8
    bounds*: BBox
    centerZoom*: uint8
    center*: LonLat

  Entry* = object
    ## One directory entry. `runLength == 0` means a leaf pointer: `length`
    ## bytes at `offset` in the leaf directories section. Otherwise tile ids
    ## `tileId ..< tileId + runLength` share `length` bytes at `offset` in the
    ## tile data section.
    tileId*: uint64
    offset*: uint64
    length*: uint32
    runLength*: uint32

  TileCoord* = object
    ## A tile coordinate: zoom `z`, column `x`, row `y`.
    z*: uint8
    x*, y*: uint32

const
  headerSize* = 127 ## Bytes in a v3 header.
  maxTileId* = 6148914691236517204'u64 ## `(4^32 - 1) / 3 - 1`, the last zoom-31 tile id.

proc newError*(code: string, kind = ekInvalidInput, offset = none(uint64),
               msg = ""): ref PMTilesError {.raises: [].} =
  ## Builds a `PMTilesError`. Used by `pmtiles/io` and by custom sources, which
  ## report read failures as `newError("pmtiles.source_failed", ekIo, msg = ...)`.
  var m = code
  if msg.len > 0: m.add ": " & msg
  if offset.isSome: m.add " at byte " & $offset.get
  (ref PMTilesError)(kind: kind, code: code, offset: offset, msg: m)

# ---------------------------------------------------------------------------
# Enums

func toCompression*(raw: uint8): Compression {.raises: [].} =
  ## Maps a raw header byte to `Compression`, keeping unknown values.
  if raw <= 4: Compression(kind: CompressionKind(raw), raw: raw)
  else: Compression(kind: ckUnknownValue, raw: raw)

func toTileType*(raw: uint8): TileType {.raises: [].} =
  ## Maps a raw header byte to `TileType`, keeping unknown values.
  if raw <= 5: TileType(kind: TileTypeKind(raw), raw: raw)
  else: TileType(kind: ttUnknownValue, raw: raw)

func compression*(kind: CompressionKind): Compression {.raises: [].} =
  ## The `Compression` for a known kind (not `ckUnknownValue`).
  Compression(kind: kind, raw: uint8(ord(kind)))

func tileType*(kind: TileTypeKind): TileType {.raises: [].} =
  ## The `TileType` for a known kind (not `ttUnknownValue`).
  TileType(kind: kind, raw: uint8(ord(kind)))

func `$`*(c: Compression): string {.raises: [].} =
  ## Spec name, or `unknown(raw)` for values outside the table.
  if c.kind == ckUnknownValue: "unknown(" & $c.raw & ")" else: $c.kind

func `$`*(t: TileType): string {.raises: [].} =
  ## Spec name, or `unknown(raw)` for values outside the table.
  if t.kind == ttUnknownValue: "unknown(" & $t.raw & ")" else: $t.kind

# ---------------------------------------------------------------------------
# decode_header

proc decodeHeader*(data: openArray[byte]): Header {.raises: [PMTilesError].} =
  ## Spec operation `decode_header`. Decodes the first 127 bytes of an archive;
  ## bytes after them are ignored.
  if data.len < headerSize:
    raise newError("pmtiles.truncated",
                   msg = "header needs 127 bytes, got " & $data.len)
  const magic = "PMTiles"
  for i in 0 ..< magic.len:
    if data[i] != byte(magic[i]):
      raise newError("pmtiles.bad_magic", msg = "first 7 bytes are not \"PMTiles\"")
  if data[7] != 3:
    raise newError("pmtiles.unsupported_version", ekUnsupported,
                   msg = "spec version " & $data[7] & ", only 3 is supported")

  template u64At(o: int): uint64 =
    var v = 0'u64
    for k in countdown(7, 0):
      v = (v shl 8) or uint64(data[o + k])
    v
  template degAt(o: int): float64 =
    let u = uint32(data[o]) or (uint32(data[o + 1]) shl 8) or
            (uint32(data[o + 2]) shl 16) or (uint32(data[o + 3]) shl 24)
    # Divide; multiplying by 1e-7 differs in the last bit.
    float64(cast[int32](u)) / 1e7
  template countAt(o: int): Option[uint64] =
    let v = u64At(o)
    if v == 0: none(uint64) else: some(v)

  Header(
    specVersion: 3,
    rootDirectoryOffset: u64At(8), rootDirectoryLength: u64At(16),
    metadataOffset: u64At(24), metadataLength: u64At(32),
    leafDirectoriesOffset: u64At(40), leafDirectoriesLength: u64At(48),
    tileDataOffset: u64At(56), tileDataLength: u64At(64),
    addressedTilesCount: countAt(72), tileEntriesCount: countAt(80),
    tileContentsCount: countAt(88),
    clustered: data[96] == 1,
    internalCompression: toCompression(data[97]),
    tileCompression: toCompression(data[98]),
    tileType: toTileType(data[99]),
    minZoom: data[100], maxZoom: data[101],
    bounds: BBox(minLon: degAt(102), minLat: degAt(106),
                 maxLon: degAt(110), maxLat: degAt(114)),
    centerZoom: data[118],
    center: LonLat(lon: degAt(119), lat: degAt(123)))

# ---------------------------------------------------------------------------
# decode_directory
#
# Hot loop. Every overflow it could hit is guarded by hand, so the compiler's
# overflow and range checks are redundant there. They stay on in test and fuzz
# builds (`-d:pmtilesChecked`), so the fuzzer still catches a missing manual
# guard. The loop never raises: on failure it records a `Failure` and returns,
# and the public proc raises once.

when defined(pmtilesChecked):
  {.push overflowChecks: on, rangeChecks: on, boundChecks: on.}
else:
  {.push overflowChecks: off, rangeChecks: off, boundChecks: off.}

# Nim checks neither unsigned arithmetic nor narrowing conversions between
# unsigned types, so `overflowChecks` and `rangeChecks` can't see a missing
# guard on the u64 sums or the u32 conversions below. In checked builds these
# helpers repeat the check as an assertion, so the fuzzer catches it there too.

template addU64(a, b: uint64): uint64 =
  when defined(pmtilesChecked):
    doAssert b <= high(uint64) - a, "unguarded u64 overflow"
  a + b

template toU32(v: uint64): uint32 =
  when defined(pmtilesChecked):
    doAssert v <= uint64(high(uint32)), "unguarded u32 conversion"
  uint32(v)

type Failure = object
  ## Built from literals only: formatting strings inside the hot loop adds
  ## cleanup code that slows it down even on the success path.
  code: string
  kind: ErrorKind
  offset: int        # byte offset into the input, -1 when unknown
  msg: string

proc readVarintSlow(data: openArray[byte], i: var int, v: var uint64,
                    err: var Failure): bool {.noinline, raises: [].} =
  ## Spec §3 `decode_directory` step 1: unsigned LEB128, at most 10 bytes, the
  ## 10th only 0 or 1.
  let start = i
  var shift = 0
  var r = 0'u64
  for n in 0 ..< 10:
    if i >= data.len:
      err = Failure(code: "pmtiles.truncated", offset: start, msg: "input ends inside a varint")
      return false
    let b = data[i]
    inc i
    if n == 9 and b > 1:
      err = Failure(code: "pmtiles.varint_overflow", offset: start, msg: "varint exceeds 64 bits")
      return false
    r = r or (uint64(b and 0x7F) shl shift)
    if b < 0x80:
      v = r
      return true
    shift += 7
  # Unreachable: a 10th byte of 0 or 1 always ends the varint.
  err = Failure(code: "pmtiles.varint_overflow", offset: start, msg: "varint exceeds 64 bits")
  false

template readVarint(data: openArray[byte], i: var int, v: var uint64,
                    err: var Failure): bool =
  ## Fast path for the common one- and two-byte varints, inlined into the loops.
  if i < data.len and data[i] < 0x80:
    v = uint64(data[i])
    inc i
    true
  elif i + 1 < data.len and data[i + 1] < 0x80:
    v = uint64(data[i] and 0x7F) or (uint64(data[i + 1]) shl 7)
    i += 2
    true
  else:
    readVarintSlow(data, i, v, err)

proc decodeEntries(data: openArray[byte], maxEntries: uint64,
                   entries: var seq[Entry], err: var Failure): bool {.raises: [].} =
  ## Spec §3 `decode_directory` steps 1-6.
  var i = 0
  var n: uint64
  if not readVarint(data, i, n, err): return false
  if n > maxEntries:
    err = Failure(code: "pmtiles.directory_too_large", kind: ekLimitExceeded, offset: -1,
                  msg: "entry count exceeds max_directory_entries")
    return false
  if n == 0: return true
  # Every varint takes at least one byte, so a count above the bytes left
  # must end in `truncated`; sizing by what the input can hold keeps a large
  # `n` from allocating before that failure is found. Past the delta loop,
  # `n <= room`, so the length is exactly `n`.
  let room = uint64(data.len - i)
  entries = newSeqUninit[Entry](int(min(n, room)))
  var last = 0'u64
  var v: uint64
  for k in 0 ..< int(min(n, room)):
    let at = i
    if not readVarint(data, i, v, err): return false
    if k > 0 and v == 0:
      err = Failure(code: "pmtiles.invalid_directory", offset: at,
                    msg: "tile ids are not strictly increasing")
      return false
    if v > high(uint64) - last:
      err = Failure(code: "pmtiles.invalid_directory", offset: at,
                    msg: "tile id exceeds 64 bits")
      return false
    last = addU64(last, v)
    entries[k] = Entry(tileId: last)
  if n > room:
    # Every byte was a one-byte delta; the next delta starts at the end.
    err = Failure(code: "pmtiles.truncated", offset: i, msg: "input ends inside a varint")
    return false
  for e in entries.mitems:
    let at = i
    if not readVarint(data, i, v, err): return false
    if v > uint64(high(uint32)):
      err = Failure(code: "pmtiles.invalid_directory", offset: at,
                    msg: "run length exceeds 32 bits")
      return false
    e.runLength = toU32(v)
  for e in entries.mitems:
    let at = i
    if not readVarint(data, i, v, err): return false
    if v > uint64(high(uint32)):
      err = Failure(code: "pmtiles.invalid_directory", offset: at,
                    msg: "length exceeds 32 bits")
      return false
    e.length = toU32(v)
  for k in 0 ..< entries.len:
    let at = i
    if not readVarint(data, i, v, err): return false
    if v == 0:
      if k == 0:
        err = Failure(code: "pmtiles.invalid_directory", offset: at,
                      msg: "first entry continues from no previous entry")
        return false
      let prev = entries[k - 1]
      if uint64(prev.length) > high(uint64) - prev.offset:
        err = Failure(code: "pmtiles.invalid_directory", offset: at,
                      msg: "offset exceeds 64 bits")
        return false
      entries[k].offset = addU64(prev.offset, uint64(prev.length))
    else:
      entries[k].offset = v - 1
  true # trailing bytes are ignored (A2)

{.pop.}

proc decodeDirectory*(data: openArray[byte], limits = Limits()): seq[Entry]
                     {.raises: [PMTilesError].} =
  ## Spec operation `decode_directory`. `data` is the directory already
  ## decompressed. Uses `limits.maxDirectoryEntries`.
  var err: Failure
  if not decodeEntries(data, limits.maxDirectoryEntries, result, err):
    raise newError(err.code, err.kind,
                   if err.offset < 0: none(uint64) else: some(uint64(err.offset)), err.msg)

# ---------------------------------------------------------------------------
# Tile ids

func rotate(n: uint64, x, y: var uint64, rx, ry: uint64) {.inline.} =
  if ry == 0:
    if rx == 1:
      x = n - 1 - x
      y = n - 1 - y
    swap(x, y)

proc zxyToTileId*(coord: TileCoord): uint64 {.raises: [PMTilesError].} =
  ## Spec operation `zxy_to_tile_id`: the Hilbert-curve tile id of `coord`.
  if coord.z > 31:
    raise newError("pmtiles.invalid_zoom", msg = "zoom " & $coord.z & " is above 31")
  let n = 1'u64 shl coord.z
  if uint64(coord.x) >= n or uint64(coord.y) >= n:
    raise newError("pmtiles.tile_out_of_range",
                   msg = $coord.x & "/" & $coord.y & " is outside zoom " & $coord.z)
  # (4^z - 1) / 3 tiles at lower zooms; below 2^62 for z <= 31.
  result = ((1'u64 shl (2 * coord.z)) - 1) div 3
  var x = uint64(coord.x)
  var y = uint64(coord.y)
  var s = n shr 1
  while s > 0:
    let rx = if (x and s) != 0: 1'u64 else: 0'u64
    let ry = if (y and s) != 0: 1'u64 else: 0'u64
    result += s * s * ((3 * rx) xor ry)
    # Only the bits below `s` matter from here on.
    x = x and (s - 1)
    y = y and (s - 1)
    rotate(s, x, y, rx, ry)
    s = s shr 1

proc tileIdToZxy*(tileId: uint64): TileCoord {.raises: [PMTilesError].} =
  ## Spec operation `tile_id_to_zxy`: the inverse of `zxyToTileId`.
  if tileId > maxTileId:
    raise newError("pmtiles.invalid_zoom", msg = "tile id is beyond zoom 31")
  var acc = 0'u64
  var z = 0'u64
  while true:
    let count = 1'u64 shl (2 * z)
    if tileId - acc < count:
      break
    acc += count
    inc z
  var t = tileId - acc
  var x, y = 0'u64
  var s = 1'u64
  let n = 1'u64 shl z
  while s < n:
    let rx = 1'u64 and (t shr 1)
    let ry = 1'u64 and (t xor rx)
    rotate(s, x, y, rx, ry)
    x += s * rx
    y += s * ry
    t = t shr 2
    s = s shl 1
  # z <= 31 and x, y < 2^31 here, so the conversions can't fail.
  TileCoord(z: uint8(z), x: uint32(x), y: uint32(y))

# ---------------------------------------------------------------------------
# find_entry

func findEntry*(entries: openArray[Entry], tileId: uint64): Option[Entry] {.raises: [].} =
  ## Spec operation `find_entry`. `entries` must be sorted by `tileId`, as
  ## `decodeDirectory` returns them. Absent when no entry covers `tileId`.
  var lo = 0
  var hi = entries.len - 1
  while lo <= hi:
    let mid = lo + (hi - lo) div 2
    let id = entries[mid].tileId
    if id < tileId: lo = mid + 1
    elif id > tileId: hi = mid - 1
    else: return some(entries[mid])
  if hi >= 0: # the last entry below tileId
    let e = entries[hi]
    if e.runLength == 0 or tileId - e.tileId < uint64(e.runLength):
      return some(e)
  none(Entry)
