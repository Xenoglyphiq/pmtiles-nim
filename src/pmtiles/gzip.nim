## Internal helpers for the io layer: a small gzip decoder (RFC 1952 around
## RFC 1951 inflate) with a hard cap on output size, and a strict UTF-8 check.
##
## The cap is the point (spec D-006): a few hundred bytes of gzip can expand
## to gigabytes, so decompression stops as soon as the output would pass the
## limit instead of checking afterwards. zippy, used before 0.2, has no such
## option. Pure Nim, no dependencies.

# Every read is guarded by hand (`pos < stop`, symbol and distance bounds), so
# the compiler's checks are off here, as in the core's hot loops, and back on in
# checked builds (`-d:pmtilesChecked`), where the fuzzer catches a missing guard.
when defined(pmtilesChecked):
  {.push overflowChecks: on, rangeChecks: on, boundChecks: on.}
else:
  {.push overflowChecks: off, rangeChecks: off, boundChecks: off.}

type
  InflateStatus* = enum
    isOk, isCorrupt, isTooLarge

  InflateError = object of CatchableError
    status: InflateStatus

  Huffman = object
    ## Canonical Huffman decoding table: code counts per length, and the
    ## symbols in code order.
    counts: array[16, int]
    symbols: seq[int]

  Inflater = object
    src: ptr UncheckedArray[byte]
    pos, stop: int
    bitBuf: uint32
    bitCount: int
    output: string
    maxOutput: int

const
  lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43,
                51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4,
                 4, 4, 4, 5, 5, 5, 5, 0]
  distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
              385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
              16385, 24577]
  distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9,
               10, 10, 11, 11, 12, 12, 13, 13]
  codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

proc fail(status: InflateStatus) {.noreturn, raises: [InflateError].} =
  var e = newException(InflateError, $status)
  e.status = status
  raise e

proc initHuffman(lengths: openArray[int]): Huffman {.raises: [InflateError].} =
  result.symbols = newSeq[int](lengths.len)
  for l in lengths: inc result.counts[l]
  result.counts[0] = 0
  # Reject over-subscribed codes (incomplete ones are allowed, as in zlib's puff).
  var left = 1
  for len in 1 .. 15:
    left = left shl 1
    left -= result.counts[len]
    if left < 0: fail(isCorrupt)
  var offsets: array[16, int]
  for len in 1 .. 14: offsets[len + 1] = offsets[len] + result.counts[len]
  for sym, l in lengths:
    if l != 0:
      result.symbols[offsets[l]] = sym
      inc offsets[l]

proc fixedLength(): Huffman {.raises: [InflateError].} =
  var l: array[288, int]
  for i in 0 .. 143: l[i] = 8
  for i in 144 .. 255: l[i] = 9
  for i in 256 .. 279: l[i] = 7
  for i in 280 .. 287: l[i] = 8
  initHuffman(l)

proc fixedDistance(): Huffman {.raises: [InflateError].} =
  var l: array[30, int]
  for i in 0 .. 29: l[i] = 5
  initHuffman(l)

proc bits(s: var Inflater, need: int): int {.inline, raises: [InflateError].} =
  while s.bitCount < need:
    if s.pos >= s.stop: fail(isCorrupt)
    s.bitBuf = s.bitBuf or (uint32(s.src[s.pos]) shl uint32(s.bitCount))
    inc s.pos
    s.bitCount += 8
  result = int(s.bitBuf and ((1'u32 shl uint32(need)) - 1))
  s.bitBuf = s.bitBuf shr uint32(need)
  s.bitCount -= need

proc decode(s: var Inflater, h: Huffman): int {.raises: [InflateError].} =
  var code, first, index = 0
  for len in 1 .. 15:
    code = code or s.bits(1)
    let count = h.counts[len]
    if code - count < first:
      return h.symbols[index + (code - first)]
    index += count
    first += count
    first = first shl 1
    code = code shl 1
  fail(isCorrupt)

proc stored(s: var Inflater) {.raises: [InflateError].} =
  s.bitBuf = 0
  s.bitCount = 0
  if s.pos + 4 > s.stop: fail(isCorrupt)
  let len = int(s.src[s.pos]) or int(s.src[s.pos + 1]) shl 8
  let nlen = int(s.src[s.pos + 2]) or int(s.src[s.pos + 3]) shl 8
  if len != (not nlen and 0xFFFF): fail(isCorrupt)
  s.pos += 4
  if s.pos + len > s.stop: fail(isCorrupt)
  if s.output.len + len > s.maxOutput: fail(isTooLarge)
  if len > 0:
    let old = s.output.len
    s.output.setLen(old + len)
    copyMem(addr s.output[old], addr s.src[s.pos], len)
  s.pos += len

proc codes(s: var Inflater, lencode, distcode: Huffman) {.raises: [InflateError].} =
  while true:
    var sym = s.decode(lencode)
    if sym < 256:
      if s.output.len >= s.maxOutput: fail(isTooLarge)
      s.output.add char(sym)
    elif sym == 256:
      return
    else:
      sym -= 257
      if sym >= 29: fail(isCorrupt)
      let len = lengthBase[sym] + s.bits(lengthExtra[sym])
      let dsym = s.decode(distcode)
      if dsym >= 30: fail(isCorrupt)
      let dist = distBase[dsym] + s.bits(distExtra[dsym])
      if dist > s.output.len: fail(isCorrupt)
      if s.output.len + len > s.maxOutput: fail(isTooLarge)
      let start = s.output.len - dist
      let old = s.output.len
      s.output.setLen(old + len)
      for i in 0 ..< len: s.output[old + i] = s.output[start + i]  # may overlap

proc dynamic(s: var Inflater) {.raises: [InflateError].} =
  let nlen = s.bits(5) + 257
  let ndist = s.bits(5) + 1
  let ncode = s.bits(4) + 4
  if nlen > 286 or ndist > 30: fail(isCorrupt)
  var lengths: array[19, int]
  for i in 0 ..< ncode: lengths[codeLengthOrder[i]] = s.bits(3)
  let lencode = initHuffman(lengths)
  var all = newSeqOfCap[int](nlen + ndist)
  while all.len < nlen + ndist:
    let sym = s.decode(lencode)
    if sym < 16:
      all.add sym
    else:
      var value = 0
      var repeat: int
      case sym
      of 16:
        if all.len == 0: fail(isCorrupt)
        value = all[^1]
        repeat = 3 + s.bits(2)
      of 17: repeat = 3 + s.bits(3)
      else: repeat = 11 + s.bits(7)
      if all.len + repeat > nlen + ndist: fail(isCorrupt)
      for _ in 0 ..< repeat: all.add value
  if all[256] == 0: fail(isCorrupt)  # the end-of-block code must exist
  s.codes(initHuffman(all.toOpenArray(0, nlen - 1)), initHuffman(all.toOpenArray(nlen, all.high)))

# CRC-32 (IEEE), slicing-by-8: table 0 is the classic byte-at-a-time table, and
# table k advances a byte's contribution by k more bytes, so the loop eats 8
# bytes per step.
const crcTables = block:
  var t: array[8, array[256, uint32]]
  for n in 0 .. 255:
    var c = uint32(n)
    for _ in 0 .. 7:
      c = if (c and 1) != 0: 0xEDB8_8320'u32 xor (c shr 1) else: c shr 1
    t[0][n] = c
  for k in 1 .. 7:
    for n in 0 .. 255:
      t[k][n] = t[0][t[k - 1][n] and 0xFF] xor (t[k - 1][n] shr 8)
  t

when defined(arm64) and defined(macosx) and not defined(pmtilesPortableCrc):
  # Every Apple arm64 CPU has the ARMv8 CRC32 instructions, and Apple clang
  # targets them by default. Elsewhere (Linux arm64 under gcc, ARMv8.0 where
  # CRC is optional, x86) the portable slicing-by-8 below is used, as it is
  # with `-d:pmtilesPortableCrc` (to test it on a Mac).
  func crc32b(crc: uint32, v: uint8): uint32 {.importc: "__builtin_arm_crc32b", nodecl.}
  func crc32d(crc: uint32, v: uint64): uint32 {.importc: "__builtin_arm_crc32d", nodecl.}

proc crc32*(s: openArray[char]): uint32 =
  var c = 0xFFFF_FFFF'u32
  if s.len == 0: return 0
  let p = cast[ptr UncheckedArray[uint8]](unsafeAddr s[0])
  var i = 0
  when defined(arm64) and defined(macosx) and not defined(pmtilesPortableCrc):
    while i + 8 <= s.len:
      var word: uint64
      copyMem(addr word, addr p[i], 8)
      c = crc32d(c, word)
      i += 8
    while i < s.len:
      c = crc32b(c, p[i])
      inc i
    return c xor 0xFFFF_FFFF'u32
  template b(k: int): uint32 = uint32(p[i + k])
  while i + 8 <= s.len:
    let lo = c xor (b(0) or b(1) shl 8 or b(2) shl 16 or b(3) shl 24)
    let hi = b(4) or b(5) shl 8 or b(6) shl 16 or b(7) shl 24
    c = crcTables[7][lo and 0xFF] xor crcTables[6][(lo shr 8) and 0xFF] xor
        crcTables[5][(lo shr 16) and 0xFF] xor crcTables[4][lo shr 24] xor
        crcTables[3][hi and 0xFF] xor crcTables[2][(hi shr 8) and 0xFF] xor
        crcTables[1][(hi shr 16) and 0xFF] xor crcTables[0][hi shr 24]
    i += 8
  while i < s.len:
    c = crcTables[0][(c xor b(0)) and 0xFF] xor (c shr 8)
    inc i
  c xor 0xFFFF_FFFF'u32

proc gunzip*(data: openArray[byte], maxOutput: int, output: var string): InflateStatus
            {.raises: [].} =
  ## Decodes one gzip member into `output`. `isTooLarge` as soon as the output
  ## would pass `maxOutput` bytes; `isCorrupt` for anything that isn't valid
  ## gzip, including a CRC-32 or length that doesn't match the trailer.
  output = ""
  if data.len < 18 or data[0] != 0x1F or data[1] != 0x8B or data[2] != 8:
    return isCorrupt
  let flags = data[3]
  if (flags and 0xE0) != 0: return isCorrupt
  var p = 10
  if (flags and 0x04) != 0:  # FEXTRA
    if p + 2 > data.len: return isCorrupt
    p += 2 + (int(data[p]) or int(data[p + 1]) shl 8)
  for flag in [0x08'u8, 0x10]:  # FNAME, FCOMMENT: zero-terminated
    if (flags and flag) != 0:
      while p < data.len and data[p] != 0: inc p
      inc p
  if (flags and 0x02) != 0: p += 2  # FHCRC
  if p > data.len - 8: return isCorrupt

  var s = Inflater(src: cast[ptr UncheckedArray[byte]](unsafeAddr data[0]),
                   pos: p, stop: data.len - 8, maxOutput: maxOutput)
  try:
    var last = 0
    while last == 0:
      last = s.bits(1)
      case s.bits(2)
      of 0: s.stored()
      of 1: s.codes(fixedLength(), fixedDistance())
      of 2: s.dynamic()
      else: fail(isCorrupt)
  except InflateError as e:
    return e.status

  let t = data.len - 8
  template u32(at: int): uint32 =
    uint32(data[at]) or uint32(data[at + 1]) shl 8 or uint32(data[at + 2]) shl 16 or
      uint32(data[at + 3]) shl 24
  if crc32(s.output) != u32(t) or uint32(s.output.len and 0xFFFF_FFFF) != u32(t + 4):
    return isCorrupt
  output = move s.output
  isOk

proc isWellFormedUtf8*(s: openArray[char]): bool =
  ## RFC 3629: no overlong forms, no encoded surrogates (U+D800..DFFF), nothing
  ## above U+10FFFF. (std/unicode's `validateUtf8` accepts the last two.)
  var i = 0
  template cont(k: int): bool = i + k < s.len and (uint8(s[i + k]) and 0xC0) == 0x80
  while i < s.len:
    let b0 = uint8(s[i])
    if b0 < 0x80:
      inc i
    elif b0 in 0xC2'u8 .. 0xDF'u8:
      if not cont(1): return false
      i += 2
    elif b0 in 0xE0'u8 .. 0xEF'u8:
      if not (cont(1) and cont(2)): return false
      let b1 = uint8(s[i + 1])
      if (b0 == 0xE0 and b1 < 0xA0) or (b0 == 0xED and b1 > 0x9F): return false
      i += 3
    elif b0 in 0xF0'u8 .. 0xF4'u8:
      if not (cont(1) and cont(2) and cont(3)): return false
      let b1 = uint8(s[i + 1])
      if (b0 == 0xF0 and b1 < 0x90) or (b0 == 0xF4 and b1 > 0x8F): return false
      i += 4
    else:
      return false
  true

{.pop.}
