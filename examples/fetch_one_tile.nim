## Canonical example `fetch_one_tile`: open a local archive as a source, fetch
## one tile, and print its byte count or "not found".
##
## Usage: fetch_one_tile [path] [z/x/y] (default: the conformance suite's small
## archive, tile 2/1/3)
import std/[os, strutils]
import pmtiles/io

let path = if paramCount() >= 1: paramStr(1)
           else: currentSourcePath().parentDir.parentDir / ".spec/conformance/cases/archives/small.pmtiles"
let arg = if paramCount() >= 2: paramStr(2) else: "2/1/3"

proc parseCoord(s: string): TileCoord =
  let p = s.split('/')
  if p.len != 3: raise newException(ValueError, "expected z/x/y")
  let (z, x, y) = (parseUInt(p[0]), parseUInt(p[1]), parseUInt(p[2]))
  if z > 255 or x > high(uint32) or y > high(uint32): raise newException(ValueError, "out of range")
  TileCoord(z: uint8(z), x: uint32(x), y: uint32(y))

try:
  let coord = parseCoord(arg)
  let tile = getTile(fileSource(path), coord)
  if tile.isSome:
    echo coord.z, "/", coord.x, "/", coord.y, ": ", tile.get.len, " bytes"
  else:
    echo coord.z, "/", coord.x, "/", coord.y, ": not found"
except ValueError:
  stderr.writeLine "expected z/x/y, got ", arg
  quit 2
except PMTilesError as e:
  stderr.writeLine e.kind, ": ", e.code
  quit 1
