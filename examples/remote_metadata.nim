## Canonical example `remote_metadata`: read an archive's metadata over HTTP
## range requests and print the JSON. Build with `-d:ssl` (examples/config.nims
## sets it).
##
## Usage: remote_metadata [url]
import std/os
import pmtiles/io

let url = if paramCount() >= 1: paramStr(1)
          else: "https://pmtiles.io/protomaps(vector)ODbL_firenze.pmtiles"

try:
  echo readMetadata(httpSource(url))
except PMTilesError as e:
  stderr.writeLine e.kind, ": ", e.code, " (", e.msg, ")"
  quit 1
