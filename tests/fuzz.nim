## Mutation fuzzer for `decodeHeader`, `decodeDirectory`, `getTile`,
## `readMetadata` and the built-in gzip decoder (no fuzzing library needed).
##
## Corpus: every `base64` and `file` input of a `decode_header` or
## `decode_directory` case in `.spec/conformance/manifest.json`, plus every
## archive in `.spec/conformance/cases/archives/`, plus real deflate streams
## (`gzipvectors`), since the archives only use stored and fixed blocks. Each
## iteration takes a
## corpus entry, applies 1-4 random mutations and runs all four operations on
## it (the io ones over a memory source holding the mutated bytes, for a few
## coordinates). Invariants:
##   - only `PMTilesError` escapes; any other exception or defect is a failure;
##   - a raised error always has a non-empty `code`;
##   - a directory that decodes has strictly increasing tile ids, and encoding
##     it again decodes to the same entries;
##   - `gunzip` never returns more than its limit, and decoding is deterministic.
##
## Environment: `FUZZ_SECONDS` (default 10), `FUZZ_SEED` (default: time-based).
## Build with overflow, range and bound checks on, and `-d:pmtilesChecked`
## (see `nimble fuzz`), so a missing guard turns into a defect the harness catches.

import std/[base64, json, monotimes, os, random, sequtils, strutils, tables, times]
import pmtiles/[gzip, io]
import builders, gzipvectors

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc loadCorpus(): seq[seq[byte]] =
  let conformance = currentSourcePath().parentDir.parentDir / ".spec" / "conformance"
  for c in parseFile(conformance / "manifest.json")["cases"].getElems:
    if c["op"].getStr notin ["decode_header", "decode_directory"]: continue
    let input = c["input"]
    if input.hasKey("base64"): result.add toBytes(decode(input["base64"].getStr))
    elif input.hasKey("file"): result.add toBytes(readFile(conformance / "cases" / input["file"].getStr))
  for path in walkFiles(conformance / "cases" / "archives" / "*.pmtiles"):
    result.add toBytes(readFile(path))
  for v in vectors: result.add bytes(v[1])

const interesting = [0'u64, 1, 0x7F, 0x80, 127, 0xFFFF_FFFF'u64, 0x1_0000_0000'u64,
                     0x7FFF_FFFF_FFFF_FFFF'u64, high(uint64), high(uint64) - 1]

proc randomValue(r: var Rand): uint64 =
  case r.rand(2)
  of 0: interesting[r.rand(interesting.high)]
  of 1: r.next() shr r.rand(63)
  else: uint64(r.rand(300))

proc position(r: var Rand, s: seq[byte]): int =
  ## Biased toward the header and the first directory, where the structure is.
  if r.rand(1) == 0: r.rand(min(s.len, 400) - 1) else: r.rand(s.len - 1)

proc mutate(r: var Rand, s: var seq[byte]) =
  case r.rand(7)
  of 0: # flip a byte (XOR with a random non-zero mask)
    if s.len > 0:
      let i = position(r, s)
      s[i] = s[i] xor byte(r.rand(1 .. 255))
  of 1: # insert a random byte
    s.insert(byte(r.rand(255)), r.rand(s.len))
  of 2: # delete a byte
    if s.len > 0:
      s.delete(position(r, s))
  of 3: # duplicate a slice
    if s.len > 0:
      let a = position(r, s)
      let b = r.rand(a .. min(s.len - 1, a + 64))
      let part = s[a .. b]
      s.insert(part, r.rand(s.len))
  of 4: # truncate
    s.setLen(r.rand(s.len))
  of 5: # insert a varint, likely large
    var v: seq[byte]
    v.addVarint randomValue(r)
    s.insert(v, if s.len > 0: position(r, s) else: 0)
  of 6: # overwrite a header u64 field (bytes 8-95)
    if s.len >= 96:
      let at = 8 * r.rand(1 .. 11)
      let v = randomValue(r)
      for k in 0 ..< 8: s[at + k] = byte((v shr (8 * k)) and 0xFF)
  else: # overwrite a header byte field (bytes 96-101, 118)
    if s.len >= 127:
      s[[96, 97, 98, 99, 100, 101, 118][r.rand(6)]] = byte(r.rand(255))

proc failWith(input: seq[byte], why: string) =
  echo "FUZZ FAILURE: ", why
  echo "input (", input.len, " bytes, base64): ", encode(input)
  quit 1

var outcomes: CountTable[string] ## how often each code was raised, plus successes

proc checkError(input: seq[byte], what: string, e: ref PMTilesError) =
  if e.code.len == 0: failWith(input, what & ": PMTilesError with empty code")
  outcomes.inc e.code

template guarded(input: seq[byte], what: string, body: untyped) =
  try:
    body
  except PMTilesError as e:
    checkError(input, what, e)
  except Defect as e:
    failWith(input, what & " raised " & $e.name & ": " & e.msg)
  except CatchableError as e:
    failWith(input, what & " raised " & $e.name & ": " & e.msg)

proc check(r: var Rand, input: seq[byte]) =
  guarded(input, "gunzip"):
    let limit = 1 shl 16
    var output, again: string
    let status = gunzip(input, limit, output)
    if output.len > limit: failWith(input, "gunzip: output above the limit")
    if status == isOk:
      outcomes.inc "gunzip succeeded"
      if gunzip(input, limit, again) != isOk or again != output:
        failWith(input, "gunzip: decoding the same input twice differs")
    elif output.len != 0:
      failWith(input, "gunzip: failed but returned output")
  guarded(input, "decodeHeader"):
    discard decodeHeader(input)

  guarded(input, "decodeDirectory"):
    let entries = decodeDirectory(input)
    outcomes.inc "decodeDirectory succeeded"
    for k in 1 ..< entries.len:
      if entries[k].tileId <= entries[k - 1].tileId:
        failWith(input, "decodeDirectory: tile ids not strictly increasing at entry " & $k)
    if decodeDirectory(encodeDirectory(entries)) != entries:
      failWith(input, "decodeDirectory: re-encoded directory decodes differently")

  let src = memorySource(input)
  guarded(input, "readMetadata"):
    discard readMetadata(src)
  for _ in 0 ..< 3:
    let z = uint8(r.rand(0 .. 9))
    let n = 1 shl z
    let coord = TileCoord(z: z, x: uint32(r.rand(n - 1)), y: uint32(r.rand(n - 1)))
    guarded(input, "getTile " & $z & "/" & $coord.x & "/" & $coord.y):
      if getTile(src, coord).isSome: outcomes.inc "getTile found a tile"

proc main() =
  let seconds = parseFloat(getEnv("FUZZ_SECONDS", "10"))
  let seed =
    if existsEnv("FUZZ_SEED"): parseBiggestInt(getEnv("FUZZ_SEED"))
    else:
      let t = getTime()
      t.toUnix * 1_000_000_000 + t.nanosecond
  echo "seed ", seed
  var r = initRand(seed)
  let corpus = loadCorpus()

  let start = getMonoTime()
  let budget = initDuration(nanoseconds = int64(seconds * 1e9))
  var iterations = 0
  while true:
    # Check the clock every 64 inputs; archive inputs are large.
    if (iterations and 63) == 0 and getMonoTime() - start >= budget: break
    var s = corpus[r.rand(corpus.len - 1)]
    for _ in 1 .. r.rand(1 .. 4):
      mutate(r, s)
    check(r, s)
    inc iterations
  let elapsed = (getMonoTime() - start).inNanoseconds.float64 / 1e9
  echo "corpus ", corpus.len, " inputs, iterations ", iterations, ", elapsed ",
    formatFloat(elapsed, ffDecimal, 1), " s, clean"
  outcomes.sort()
  for what, n in outcomes: echo "  ", n, " ", what

when isMainModule:
  main()
