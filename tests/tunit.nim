## Unit tests. The conformance runner (`tests/tconformance.nim`) is the real
## suite; these cover the spec's vectors, open enums, leaf following and the io
## errors the fixtures don't reach.

import std/[os, unittest]
import pmtiles/io
import builders

const casesDir = currentSourcePath().parentDir.parentDir / ".spec" / "conformance" / "cases"

proc errorOf(body: proc () {.raises: [PMTilesError].}): ref PMTilesError =
  try:
    body()
  except PMTilesError as e:
    return e
  nil

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc tile(n: int, fill: char): seq[byte] =
  for _ in 0 ..< n: result.add byte(fill)

suite "tile ids":
  test "spec vectors":
    for (z, x, y, id) in [(0, 0, 0, 0'u64), (1, 0, 0, 1), (1, 0, 1, 2), (1, 1, 1, 3),
                          (1, 1, 0, 4), (2, 0, 0, 5), (3, 0, 0, 21),
                          (12, 3423, 1763, 19078479)]:
      let c = TileCoord(z: uint8(z), x: uint32(x), y: uint32(y))
      check zxyToTileId(c) == id
      check tileIdToZxy(id) == c

  test "round trip at every zoom's corners":
    for z in 0'u8 .. 31:
      let m = uint32((1'u64 shl z) - 1)
      for (x, y) in [(0'u32, 0'u32), (m, 0'u32), (0'u32, m), (m, m)]:
        let c = TileCoord(z: z, x: x, y: y)
        check tileIdToZxy(zxyToTileId(c)) == c

  test "the last zoom-31 id, and one past it":
    check tileIdToZxy(maxTileId) == TileCoord(z: 31, x: 2147483647, y: 0)
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard tileIdToZxy(maxTileId + 1))
    check e != nil and e.code == "pmtiles.invalid_zoom" and e.kind == ekInvalidInput

  test "coordinate errors":
    let z = errorOf(proc () {.raises: [PMTilesError].} =
      discard zxyToTileId(TileCoord(z: 32)))
    check z != nil and z.code == "pmtiles.invalid_zoom"
    let x = errorOf(proc () {.raises: [PMTilesError].} =
      discard zxyToTileId(TileCoord(z: 31, x: high(uint32), y: 0)))
    check x != nil and x.code == "pmtiles.tile_out_of_range"

suite "header":
  let small = toBytes(readFile(casesDir / "header" / "small.bin"))

  test "decodes the small archive's header":
    let h = decodeHeader(small)
    check h.specVersion == 3
    check h.rootDirectoryOffset == 127
    check h.internalCompression == compression(ckGzip)
    check h.tileType == tileType(ttUnknown)
    check h.clustered
    check h.minZoom == 0 and h.maxZoom == 3
    check abs(h.bounds.minLon - -74.259) < 1e-12
    check abs(h.center.lat - 40.75) < 1e-12

  test "unknown enum raw values are kept; zero counts are absent":
    var b = small
    b[98] = 9
    b[99] = 42
    for i in 72 ..< 96: b[i] = 0
    let h = decodeHeader(b)
    check h.tileCompression.kind == ckUnknownValue
    check h.tileCompression.raw == 9
    check $h.tileCompression == "unknown(9)"
    check h.tileType.kind == ttUnknownValue
    check h.tileType.raw == 42
    check h.addressedTilesCount.isNone
    check h.tileEntriesCount.isNone
    check h.tileContentsCount.isNone

  test "known raw values map to their names":
    for raw in 0'u8 .. 4:
      check toCompression(raw).kind == CompressionKind(raw)
      check toCompression(raw) == compression(CompressionKind(raw))
    check $toCompression(2) == "gzip"
    check $toTileType(5) == "avif"

  test "errors in spec order":
    let short = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeHeader(toBytes("NOPEs")))
    check short != nil and short.code == "pmtiles.truncated" and short.kind == ekInvalidInput
    var v2 = small
    v2[7] = 2
    let ver = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeHeader(v2))
    check ver != nil and ver.code == "pmtiles.unsupported_version" and ver.kind == ekUnsupported

suite "directory":
  test "round trip with explicit and continued offsets":
    let entries = @[
      Entry(tileId: 5, offset: 0, length: 10, runLength: 1),
      Entry(tileId: 6, offset: 10, length: 3, runLength: 4),
      Entry(tileId: 20, offset: 100, length: 7, runLength: 0),
      Entry(tileId: high(uint64), offset: high(uint64) - 1, length: high(uint32), runLength: high(uint32)),
    ]
    check decodeDirectory(encodeDirectory(entries)) == entries

  test "errors carry the varint's byte offset":
    # 2 entries; the second tile-id delta (byte 2) is 0.
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeDirectory([2'u8, 5, 0, 1, 1, 1, 1, 1, 0]))
    check e != nil and e.code == "pmtiles.invalid_directory" and e.offset == some(2'u64)

  test "a tile id beyond 64 bits":
    var b: seq[byte]
    b.addVarint 2
    b.addVarint high(uint64)
    b.addVarint 1
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeDirectory(b))
    check e != nil and e.code == "pmtiles.invalid_directory"

  test "values above 32 bits":
    var b: seq[byte]
    b.addVarint 1
    b.addVarint 0
    b.addVarint 1'u64 shl 32
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeDirectory(b))
    check e != nil and e.code == "pmtiles.invalid_directory"

  test "a continued offset beyond 64 bits":
    var c: seq[byte]
    c.addVarint 2
    c.addVarint 1
    c.addVarint 1
    c.addVarint 1
    c.addVarint 1
    c.addVarint 5
    c.addVarint 5
    c.addVarint high(uint64) # offset high(uint64) - 1
    c.addVarint 0            # continue: overflows
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeDirectory(c))
    check e != nil and e.code == "pmtiles.invalid_directory"

  test "a huge count inside the limit doesn't allocate before failing":
    var b: seq[byte]
    b.addVarint 900_000
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard decodeDirectory(b))
    check e != nil and e.code == "pmtiles.truncated"

  test "limits keep their defaults when one is set":
    check Limits().maxDirectoryEntries == 1_000_000'u64
    check Limits().maxDirectoryBytes == 16'u64 * 1024 * 1024
    check Limits().maxLeafDepth == 4'u32
    check Limits(maxLeafDepth: 1).maxMetadataBytes == 16'u64 * 1024 * 1024

suite "find_entry":
  let entries = @[
    Entry(tileId: 2, offset: 0, length: 1, runLength: 3),
    Entry(tileId: 10, offset: 1, length: 1, runLength: 0),
    Entry(tileId: 50, offset: 2, length: 1, runLength: 1),
  ]
  test "runs, leaf pointers and gaps":
    check findEntry(entries, 1).isNone
    check findEntry(entries, 4).get.tileId == 2
    check findEntry(entries, 5).isNone
    check findEntry(entries, 49).get.tileId == 10
    check findEntry(entries, 50).get.tileId == 50
    check findEntry(entries, 51).isNone
    check findEntry(newSeq[Entry](), 0).isNone

suite "io":
  test "follows a leaf directory":
    let tiles = tile(3, 'a') & tile(5, 'b')
    let leaf = encodeDirectory([Entry(tileId: 0, offset: 0, length: 3, runLength: 1),
                                Entry(tileId: 1, offset: 3, length: 5, runLength: 2)])
    let root = encodeDirectory([Entry(tileId: 0, offset: 0, length: uint32(leaf.len), runLength: 0)])
    let src = memorySource(buildArchive(root, toBytes("{}"), leaf, tiles))
    check getTile(src, TileCoord(z: 0)) == some(tile(3, 'a'))
    check getTile(src, TileCoord(z: 1, x: 0, y: 1)) == some(tile(5, 'b'))
    check getTile(src, TileCoord(z: 1, x: 1, y: 1)).isNone
    check readMetadata(src) == "{}"

  test "a leaf directory that points to itself hits max_leaf_depth":
    # One leaf pointer at leaf offset 0 whose directory is itself.
    let self = encodeDirectory([Entry(tileId: 0, offset: 0, length: 5, runLength: 0)])
    check self.len == 5
    let src = memorySource(buildArchive(self, [], self, []))
    for depth in [0'u32, 1, 4]:
      let e = errorOf(proc () {.raises: [PMTilesError].} =
        discard getTile(src, TileCoord(z: 0), Limits(maxLeafDepth: depth)))
      check e != nil and e.code == "pmtiles.leaf_depth_exceeded" and e.kind == ekLimitExceeded

  test "directory and metadata limits are checked before reading":
    let src = fileSource(casesDir / "archives" / "small.pmtiles")
    let d = errorOf(proc () {.raises: [PMTilesError].} =
      discard getTile(src, TileCoord(z: 0), Limits(maxDirectoryBytes: 10)))
    check d != nil and d.code == "pmtiles.directory_too_large" and d.kind == ekLimitExceeded
    let m = errorOf(proc () {.raises: [PMTilesError].} =
      discard readMetadata(src, Limits(maxMetadataBytes: 10)))
    check m != nil and m.code == "pmtiles.metadata_too_large" and m.kind == ekLimitExceeded

  test "brotli and zstd are unsupported":
    for raw in [3'u8, 4]:
      let src = memorySource(buildArchive(encodeDirectory(newSeq[Entry]()), toBytes("{}"), [], [], raw))
      let e = errorOf(proc () {.raises: [PMTilesError].} =
        discard readMetadata(src))
      check e != nil and e.code == "pmtiles.unsupported_compression" and e.kind == ekUnsupported

  test "a gzip directory that doesn't decompress":
    let src = memorySource(buildArchive(toBytes("not gzip at all, but long enough"),
                                        toBytes("{}"), [], [], 2))
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard getTile(src, TileCoord(z: 0)))
    check e != nil and e.code == "pmtiles.invalid_directory"

  test "a source that ends early":
    let full = buildArchive(encodeDirectory([Entry(tileId: 0, offset: 0, length: 4, runLength: 1)]),
                            toBytes("{}"), [], tile(4, 't'))
    let src = memorySource(full[0 ..< full.len - 1])
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard getTile(src, TileCoord(z: 0)))
    check e != nil and e.code == "pmtiles.truncated"
    let tiny = errorOf(proc () {.raises: [PMTilesError].} =
      discard readMetadata(memorySource(full[0 ..< 50])))
    check tiny != nil and tiny.code == "pmtiles.truncated"

  test "source failures are io errors":
    let missing = errorOf(proc () {.raises: [PMTilesError].} =
      discard fileSource(casesDir / "no-such-file.pmtiles"))
    check missing != nil and missing.code == "pmtiles.source_failed" and missing.kind == ekIo
    let failing = newSource(proc (offset, length: uint64): seq[byte]
                                {.closure, raises: [PMTilesError].} =
      raise newError("pmtiles.source_failed", ekIo, msg = "offline"))
    let e = errorOf(proc () {.raises: [PMTilesError].} =
      discard getTile(failing, TileCoord(z: 0)))
    check e != nil and e.code == "pmtiles.source_failed" and e.kind == ekIo

  test "file and memory sources read the same ranges":
    let path = casesDir / "archives" / "leaves.pmtiles"
    let f = fileSource(path)
    let m = memorySource(toBytes(readFile(path)))
    for (o, n) in [(0'u64, 127'u64), (100'u64, 5000'u64), (138590'u64, 100'u64),
                   (1_000_000'u64, 10'u64), (high(uint64), high(uint64))]:
      check f.readRange(o, n) == m.readRange(o, n)
