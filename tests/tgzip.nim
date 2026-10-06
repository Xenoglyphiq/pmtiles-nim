## Unit tests for the built-in gzip decoder and the strict UTF-8 check.
## The conformance archives only use stored and fixed-Huffman blocks (spec
## D-004), so real dynamic-Huffman streams are tested here (`gzipvectors`).

import std/unittest
import pmtiles/gzip
import gzipvectors

suite "gzip":
  test "CRC-32 check value":
    check crc32("123456789") == 0xCBF4_3926'u32
    check crc32("") == 0
    var long = newString(1037)
    for i in 0 ..< long.len: long[i] = char((i * 31 + 7) and 0xFF)
    check crc32(long) == 0x1911_DE9A'u32  # Python's zlib.crc32

  for v in vectors:
    test "decodes real deflate: " & v[0]:
      var output: string
      check gunzip(bytes(v[1]), 1 shl 24, output) == isOk
      check output.len == v[3]
      check crc32(output) == v[2]

  test "stops at the output limit":
    var output: string
    check gunzip(bytes(bomb), 1 shl 20, output) == isTooLarge
    check output.len == 0

  test "a limit exactly at the output size is allowed":
    let v = vectors[4]  # long_matches: 80,000 bytes
    var output: string
    check gunzip(bytes(v[1]), v[3], output) == isOk
    check gunzip(bytes(v[1]), v[3] - 1, output) == isTooLarge

  test "rejects corruption":
    var output: string
    var gz = bytes(vectors[0][1])
    gz[gz.len - 9] = gz[gz.len - 9] xor 0xFF  # last deflate byte
    check gunzip(gz, 1 shl 24, output) != isOk
    var badCrc = bytes(vectors[0][1])
    badCrc[badCrc.len - 8] = badCrc[badCrc.len - 8] xor 1
    check gunzip(badCrc, 1 shl 24, output) == isCorrupt
    check gunzip(bytes(vectors[0][1])[0 ..< 20], 1 shl 24, output) == isCorrupt
    check gunzip(newSeq[byte](), 1 shl 24, output) == isCorrupt

suite "utf-8":
  test "accepts well-formed text":
    for s in ["", "plain ascii", "caf\xc3\xa9", "\xe2\x9c\x93", "\xf0\x9f\x97\xba", "\xf4\x8f\xbf\xbf", "\xed\x9f\xbf"]:
      check isWellFormedUtf8(s)

  test "rejects everything RFC 3629 forbids":
    for s in ["caf\xe9", "\x80", "\xc0\xaf", "\xc1\xbf", "\xe0\x80\xaf", "\xed\xa0\x80", "\xed\xbf\xbf",
              "\xf0\x80\x80\xaf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", "\xe2\x9c", "\xf0\x9f\x97"]:
      check not isWellFormedUtf8(s)
