## Canonical example `inspect_archive`: read the first 127 bytes of a local
## archive, decode the header, and print the zooms, bounds and tile type.
##
## Usage: inspect_archive [path] (default: the conformance suite's small archive)
import std/os
import pmtiles

let path = if paramCount() >= 1: paramStr(1)
           else: currentSourcePath().parentDir.parentDir / ".spec/conformance/cases/archives/small.pmtiles"

try:
  var head = newSeq[byte](headerSize)
  let f = open(path)
  let n = f.readBytes(head, 0, headerSize)
  f.close()
  head.setLen(n)
  let h = decodeHeader(head)
  echo "zooms ", h.minZoom, "-", h.maxZoom, " (center zoom ", h.centerZoom, ")"
  echo "bounds lon ", h.bounds.minLon, " to ", h.bounds.maxLon,
    ", lat ", h.bounds.minLat, " to ", h.bounds.maxLat
  echo "tile type ", h.tileType, ", tile compression ", h.tileCompression
except IOError as e:
  stderr.writeLine "cannot read ", path, ": ", e.msg
  quit 1
except PMTilesError as e:
  stderr.writeLine e.kind, ": ", e.code
  quit 1
