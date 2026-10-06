## Builders shared by the unit tests and the fuzzer: varints, directories and
## small hand-made archives.

import pmtiles

proc addVarint*(s: var seq[byte], v: uint64) =
  var v = v
  while v >= 0x80:
    s.add byte((v and 0x7F) or 0x80)
    v = v shr 7
  s.add byte(v)

proc encodeDirectory*(entries: openArray[Entry]): seq[byte] =
  ## The inverse of `decodeDirectory`: offsets that continue the previous entry
  ## are stored as 0, others as offset + 1.
  result.addVarint uint64(entries.len)
  var last = 0'u64
  for e in entries:
    result.addVarint e.tileId - last
    last = e.tileId
  for e in entries: result.addVarint e.runLength
  for e in entries: result.addVarint e.length
  for k, e in entries:
    if k > 0 and e.offset == entries[k - 1].offset + uint64(entries[k - 1].length):
      result.addVarint 0
    else:
      result.addVarint e.offset + 1

proc putU64(s: var seq[byte], at: int, v: uint64) =
  for k in 0 ..< 8: s[at + k] = byte((v shr (8 * k)) and 0xFF)

proc putI32(s: var seq[byte], at: int, v: int32) =
  let u = cast[uint32](v)
  for k in 0 ..< 4: s[at + k] = byte((u shr (8 * k)) and 0xFF)

proc buildArchive*(root, metadata, leaves, tiles: openArray[byte],
                   internalCompression = 1'u8): seq[byte] =
  ## An archive laid out as header, root, metadata, leaves, tile data. The
  ## sections are stored as given (already compressed, if at all).
  result = newSeq[byte](127)
  for i, c in "PMTiles": result[i] = byte(c)
  result[7] = 3
  var at = 127'u64
  for (field, part) in [(8, root.len), (24, metadata.len), (40, leaves.len), (56, tiles.len)]:
    result.putU64(field, at)
    result.putU64(field + 8, uint64(part))
    at += uint64(part)
  result[96] = 1
  result[97] = internalCompression
  result[98] = 1
  result[99] = 1
  result[100] = 0
  result[101] = 31
  result.putI32(102, -1_800_000_000)
  result.putI32(106, -850_511_287)
  result.putI32(110, 1_800_000_000)
  result.putI32(114, 850_511_287)
  result.add root
  result.add metadata
  result.add leaves
  result.add tiles
