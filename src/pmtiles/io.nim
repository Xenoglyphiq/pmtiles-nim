## PMTiles v3 reader, io layer: byte sources (memory, local file, HTTP range
## requests), internal decompression, and the spec operations `get_tile` and
## `read_metadata`.
##
## Re-exports the core module, so `import pmtiles/io` is enough.
##
## Internal compression: `none` and `gzip` (via zippy). `brotli`, `zstd`,
## `unknown` and unknown raw values raise `pmtiles.unsupported_compression`.
##
## `httpSource` uses `std/httpclient`; build with `-d:ssl` for `https` URLs.

import std/httpclient
import zippy
import ../pmtiles

export pmtiles

type
  ReadRange* = proc (offset, length: uint64): seq[byte] {.closure, raises: [PMTilesError].}
    ## Returns up to `length` bytes starting at `offset`. Fewer bytes (possibly
    ## none) means the source ends there. A failed read raises `PMTilesError`
    ## with kind `ekIo` and code `pmtiles.source_failed`.

  Source* = object
    ## Where archive bytes come from. Build one with `memorySource`,
    ## `fileSource`, `httpSource`, or `newSource` for your own backend.
    readRange*: ReadRange

proc sourceFailed(msg: string): ref PMTilesError {.raises: [].} =
  newError("pmtiles.source_failed", ekIo, msg = msg)

proc newSource*(readRange: ReadRange): Source {.raises: [].} =
  ## A source backed by your own `readRange` proc.
  Source(readRange: readRange)

func clampRange(size, offset, length: uint64): (uint64, uint64) {.inline, raises: [].} =
  ## The part of `[offset, offset + length)` inside `[0, size)`, as (start, count).
  let start = min(offset, size)
  (start, min(length, size - start))

proc memorySource*(data: seq[byte]): Source {.raises: [].} =
  ## A source over bytes already in memory.
  let data = data
  newSource(proc (offset, length: uint64): seq[byte] {.closure, raises: [].} =
    let (start, count) = clampRange(uint64(data.len), offset, length)
    result = newSeqUninit[byte](int(count))
    if count > 0:
      copyMem(addr result[0], unsafeAddr data[int(start)], int(count)))

type FileBox = object
  f: File

proc `=destroy`(b: FileBox) =
  if b.f != nil: close(b.f)

proc `=copy`(a: var FileBox, b: FileBox) {.error.}

proc fileSource*(path: string): Source {.raises: [PMTilesError].} =
  ## A source over a local file. The file stays open until the source (and
  ## every copy of it) goes out of scope.
  var f: File
  if not open(f, path, fmRead):
    raise sourceFailed("cannot open " & path)
  let box = (ref FileBox)(f: f)
  var size: int64
  try:
    size = getFileSize(f)
  except IOError as e:
    raise sourceFailed("cannot read the size of " & path & ": " & e.msg)
  let fileSize = uint64(max(size, 0))
  newSource(proc (offset, length: uint64): seq[byte] {.closure, raises: [PMTilesError].} =
    let (start, count) = clampRange(fileSize, offset, length)
    result = newSeqUninit[byte](int(count))
    if count == 0: return
    try:
      setFilePos(box.f, int64(start))
      if readBuffer(box.f, addr result[0], int(count)) != int(count):
        raise sourceFailed("short read from " & path)
    except IOError as e:
      raise sourceFailed("read failed on " & path & ": " & e.msg))

proc httpSource*(url: string, timeoutMs = 30_000): Source {.raises: [].} =
  ## A source that fetches byte ranges over HTTP(S) with `Range` requests.
  ## A server that ignores `Range` and sends the whole file still works, just
  ## slowly. Build with `-d:ssl` for `https` URLs.
  newSource(proc (offset, length: uint64): seq[byte] {.closure, raises: [PMTilesError].} =
    if length == 0: return @[]
    let last = if offset > high(uint64) - (length - 1): high(uint64)
               else: offset + (length - 1)
    var body: string
    var status: int
    try:
      let client = newHttpClient(timeout = timeoutMs)
      try:
        let resp = client.request(url, HttpGet,
          # Ask for the bytes as stored: a server that compresses the response
          # applies the range to the compressed form, which gives wrong bytes.
          headers = newHttpHeaders({"Range": "bytes=" & $offset & "-" & $last,
                                    "Accept-Encoding": "identity"}))
        status = resp.code.int
        body = resp.body
      finally:
        client.close()
    except Defect as e:
      raise e # a bug, not a failed read
    except Exception as e:
      # std/httpclient raises a wide range of exceptions, and its effects
      # include the base `Exception`; every one of them is a failed read.
      raise sourceFailed("GET " & url & " failed: " & e.msg)
    case status
    of 206:
      discard
    of 200:
      # The server ignored the range and sent the whole file.
      let (start, count) = clampRange(uint64(body.len), offset, length)
      body = body.substr(int(start), int(start + count) - 1)
    of 416:
      return @[] # range starts beyond the end
    else:
      raise sourceFailed("GET " & url & " returned HTTP " & $status)
    let n = min(uint64(body.len), length)
    result = newSeqUninit[byte](int(n))
    if n > 0:
      copyMem(addr result[0], addr body[0], int(n)))

# ---------------------------------------------------------------------------
# Reading and decompression

proc readExact(src: Source, offset, length: uint64, what: string): seq[byte]
              {.raises: [PMTilesError].} =
  result = src.readRange(offset, length)
  if uint64(result.len) < length:
    raise newError("pmtiles.truncated", offset = some(offset),
                   msg = what & " needs " & $length & " bytes, the source has " & $result.len)
  if uint64(result.len) > length:
    result.setLen(int(length))

proc decompress(data: sink seq[byte], c: Compression, failCode, what: string): string
               {.raises: [PMTilesError].} =
  ## Internal decompression (spec §3, Decompression). `failCode` is the error
  ## for a stream that doesn't decompress.
  case c.kind
  of ckNone:
    result = newString(data.len)
    if data.len > 0:
      copyMem(addr result[0], addr data[0], data.len)
  of ckGzip:
    if data.len == 0:
      raise newError(failCode, msg = what & " is not valid gzip: empty")
    try:
      result = uncompress(addr data[0], data.len, dfGzip)
    except ZippyError as e:
      raise newError(failCode, msg = what & " is not valid gzip: " & e.msg)
  of ckUnknown, ckBrotli, ckZstd, ckUnknownValue:
    raise newError("pmtiles.unsupported_compression", ekUnsupported,
                   msg = "internal compression " & $c & " is not supported")

proc checkedAdd(a, b: uint64, what: string): uint64 {.raises: [PMTilesError].} =
  if b > high(uint64) - a:
    raise newError("pmtiles.invalid_directory", msg = what & " exceeds 64 bits")
  a + b

proc readHeader(src: Source): Header {.raises: [PMTilesError].} =
  decodeHeader(src.readRange(0, headerSize))

proc getTile*(src: Source, coord: TileCoord, limits = Limits()): Option[seq[byte]]
             {.raises: [PMTilesError].} =
  ## Spec operation `get_tile`. The bytes of tile `coord`, still compressed
  ## with `header.tileCompression`, or absent when the archive has no such
  ## tile. Follows leaf directories up to `limits.maxLeafDepth`.
  let h = readHeader(src)
  let tileId = zxyToTileId(coord)
  var offset = h.rootDirectoryOffset
  var length = h.rootDirectoryLength
  var depth = 0'u32
  while true:
    if length > limits.maxDirectoryBytes:
      raise newError("pmtiles.directory_too_large", ekLimitExceeded,
                     msg = "directory is " & $length & " bytes, limit " & $limits.maxDirectoryBytes)
    let dir = decompress(readExact(src, offset, length, "directory"),
                         h.internalCompression, "pmtiles.invalid_directory", "directory")
    let entries = decodeDirectory(dir.toOpenArrayByte(0, dir.high), limits)
    let found = findEntry(entries, tileId)
    if found.isNone:
      return none(seq[byte])
    let e = found.get
    if e.runLength > 0:
      let start = checkedAdd(h.tileDataOffset, e.offset, "tile offset")
      return some(readExact(src, start, uint64(e.length), "tile"))
    if depth >= limits.maxLeafDepth:
      raise newError("pmtiles.leaf_depth_exceeded", ekLimitExceeded,
                     msg = "leaf directories nested deeper than " & $limits.maxLeafDepth)
    inc depth
    offset = checkedAdd(h.leafDirectoriesOffset, e.offset, "leaf directory offset")
    length = uint64(e.length)

proc readMetadata*(src: Source, limits = Limits()): string {.raises: [PMTilesError].} =
  ## Spec operation `read_metadata`. The archive's JSON metadata, decompressed
  ## but not parsed.
  let h = readHeader(src)
  if h.metadataLength > limits.maxMetadataBytes:
    raise newError("pmtiles.metadata_too_large", ekLimitExceeded,
                   msg = "metadata is " & $h.metadataLength & " bytes, limit " &
                         $limits.maxMetadataBytes)
  decompress(readExact(src, h.metadataOffset, h.metadataLength, "metadata"),
             h.internalCompression, "pmtiles.truncated", "metadata")
