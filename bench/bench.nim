## Benchmark per `.spec/bench/README.md`: load `bench.pmtiles` into a memory
## source once; 3 warm-up passes, then 15 timed passes, each calling `getTile`
## for every coordinate in `coords.txt`; report the median and min per pass.
## Every pass must return 998,434 tile bytes in total.
##
## Run: `nimble bench` (built with -d:release). The input directory is the
## first argument, else `BENCH_DIR`, else `.spec/bench`.

import std/[algorithm, monotimes, os, strformat, strutils, times]
import pmtiles/io

const
  warmup = 3
  runs = 15
  checksum = 998_434

proc main() =
  let dir = if paramCount() >= 1: paramStr(1) else: getEnv("BENCH_DIR", ".spec/bench")
  let raw = readFile(dir / "bench.pmtiles")
  var archive = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr archive[0], unsafeAddr raw[0], raw.len)
  var coords: seq[TileCoord]
  for line in lines(dir / "coords.txt"):
    if line.len == 0: continue
    let p = line.split('/')
    coords.add TileCoord(z: uint8(parseUInt(p[0])), x: uint32(parseUInt(p[1])),
                         y: uint32(parseUInt(p[2])))
  let src = memorySource(archive)

  var ms: seq[float]
  for run in 0 ..< warmup + runs:
    let start = getMonoTime()
    var total = 0
    for c in coords:
      let tile = getTile(src, c)
      if tile.isSome: total += tile.get.len
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e6
    doAssert total == checksum, &"checksum mismatch: got {total}, want {checksum}"
    if run >= warmup: ms.add elapsed
  ms.sort()
  echo &"pmtiles nim {NimVersion} -d:release ({coords.len} lookups): " &
    &"get_tile pass median {ms[runs div 2]:.3f} ms (min {ms[0]:.3f}), checksum {checksum} ok"

main()
