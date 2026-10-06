# Package

version       = "0.1.0"
author        = "Xenoglyphiq contributors"
description   = "Read PMTiles v3 tile archives: header, directories, tile lookup and tile bytes"
license       = "MIT OR Apache-2.0"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.12"
requires "zippy >= 0.10.20"

# Tasks

task conformance, "Run every case in .spec/conformance/manifest.json":
  exec "nim c --hints:off -r tests/tconformance.nim"

task examples, "Run the three canonical examples (remote_metadata needs network)":
  for name in ["inspect_archive", "fetch_one_tile", "remote_metadata"]:
    exec "nim c --hints:off -r examples/" & name & ".nim"

task fuzz, "Mutation-fuzz decodeHeader, decodeDirectory, getTile and readMetadata (FUZZ_SECONDS, default 10; FUZZ_SEED)":
  exec "nim c --hints:off -d:release -d:pmtilesChecked --overflowChecks:on --rangeChecks:on " &
    "--boundChecks:on -r tests/fuzz.nim"

task bench, "Time getTile over .spec/bench/ (BENCH_DIR overrides the directory)":
  exec "nim c --hints:off -d:release -r bench/bench.nim"
