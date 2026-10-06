## Conformance runner: loads `.spec/conformance/manifest.json`, runs every case,
## converts results to canonical JSON and compares them the way the case says
## to (`exact`, `float_tol`, `json_equal` or `bytes`).
##
## `file` inputs are read from the `cases/` directory next to the manifest.
## io cases run against both a file source and a memory source, which must agree.
##
## Usage: `nimble conformance` (or `tconformance [manifest.json]`).
## Exit code 0 only if every case passes.

import std/[base64, json, os, strutils]
import pmtiles/io

type CaseError = object of CatchableError

proc bad(msg: string): ref CaseError = newException(CaseError, msg)

# ---------------------------------------------------------------------------
# Canonical JSON in

proc toU64(v: JsonNode): uint64 =
  ## Canonical u64: a number, or a decimal string beyond 2^53.
  case v.kind
  of JInt:
    if v.getBiggestInt < 0: raise bad("negative u64 " & $v)
    uint64(v.getBiggestInt)
  of JString: parseBiggestUInt(v.getStr)
  else: raise bad("bad u64 " & $v)

proc toU32(v: JsonNode): uint32 =
  let n = toU64(v)
  if n > uint64(high(uint32)): raise bad("u32 out of range " & $v)
  uint32(n)

proc toCoord(v: JsonNode): TileCoord =
  let z = toU64(v["z"])
  if z > 255: raise bad("zoom out of u8 range " & $v)
  TileCoord(z: uint8(z), x: toU32(v["x"]), y: toU32(v["y"]))

proc toEntry(v: JsonNode): Entry =
  Entry(tileId: toU64(v["tile_id"]), offset: toU64(v["offset"]),
        length: toU32(v["length"]), runLength: toU32(v["run_length"]))

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc inputBytes(input: JsonNode, casesDir: string): seq[byte] =
  if input.hasKey("base64"): toBytes(decode(input["base64"].getStr))
  elif input.hasKey("file"): toBytes(readFile(casesDir / input["file"].getStr))
  else: raise bad("input has neither base64 nor file")

# ---------------------------------------------------------------------------
# Canonical JSON out

proc u64Json(n: uint64): JsonNode =
  if n <= 9007199254740992'u64: newJInt(BiggestInt(n)) else: newJString($n)

proc optJson(o: Option[uint64]): JsonNode =
  if o.isSome: u64Json(o.get) else: newJNull()

proc enumJson(name: string, isUnknownValue: bool, raw: uint8): JsonNode =
  if isUnknownValue: %*{"unknown": int(raw)} else: newJString(name)

proc toJson(h: Header): JsonNode =
  %*{
    "spec_version": int(h.specVersion),
    "root_directory_offset": u64Json(h.rootDirectoryOffset),
    "root_directory_length": u64Json(h.rootDirectoryLength),
    "metadata_offset": u64Json(h.metadataOffset),
    "metadata_length": u64Json(h.metadataLength),
    "leaf_directories_offset": u64Json(h.leafDirectoriesOffset),
    "leaf_directories_length": u64Json(h.leafDirectoriesLength),
    "tile_data_offset": u64Json(h.tileDataOffset),
    "tile_data_length": u64Json(h.tileDataLength),
    "addressed_tiles_count": optJson(h.addressedTilesCount),
    "tile_entries_count": optJson(h.tileEntriesCount),
    "tile_contents_count": optJson(h.tileContentsCount),
    "clustered": h.clustered,
    "internal_compression": enumJson($h.internalCompression.kind,
      h.internalCompression.kind == ckUnknownValue, h.internalCompression.raw),
    "tile_compression": enumJson($h.tileCompression.kind,
      h.tileCompression.kind == ckUnknownValue, h.tileCompression.raw),
    "tile_type": enumJson($h.tileType.kind, h.tileType.kind == ttUnknownValue, h.tileType.raw),
    "min_zoom": int(h.minZoom),
    "max_zoom": int(h.maxZoom),
    "bounds": {"min_lon": h.bounds.minLon, "min_lat": h.bounds.minLat,
               "max_lon": h.bounds.maxLon, "max_lat": h.bounds.maxLat},
    "center_zoom": int(h.centerZoom),
    "center": {"lon": h.center.lon, "lat": h.center.lat},
  }

proc toJson(e: Entry): JsonNode =
  %*{"tile_id": u64Json(e.tileId), "offset": u64Json(e.offset),
     "length": int(e.length), "run_length": int(e.runLength)}

proc toJson(c: TileCoord): JsonNode =
  %*{"z": int(c.z), "x": int(c.x), "y": int(c.y)}

# ---------------------------------------------------------------------------
# Comparison

proc isNumber(v: JsonNode): bool = v.kind in {JInt, JFloat}

proc asFloat(v: JsonNode): float64 =
  if v.kind == JInt: float64(v.getBiggestInt) else: v.getFloat

proc closeTo(got, want: JsonNode, tol: float64, path: string, why: var string): bool =
  ## Deep comparison where numbers match within `tol` and everything else exactly.
  if got.isNumber and want.isNumber:
    if got.kind == JInt and want.kind == JInt:
      if got.getBiggestInt == want.getBiggestInt: return true
    elif abs(got.asFloat - want.asFloat) <= tol:
      return true
    why = path & ": expected " & $want & ", got " & $got
    return false
  if got.kind != want.kind:
    why = path & ": expected " & $want & ", got " & $got
    return false
  case want.kind
  of JObject:
    if got.len != want.len:
      why = path & ": expected keys " & $want.len & ", got " & $got.len
      return false
    for k, w in want.pairs:
      if not got.hasKey(k):
        why = path & ": missing key " & k
        return false
      if not closeTo(got[k], w, tol, path & "." & k, why): return false
    true
  of JArray:
    if got.len != want.len:
      why = path & ": expected " & $want.len & " items, got " & $got.len
      return false
    for i in 0 ..< want.len:
      if not closeTo(got[i], want[i], tol, path & "[" & $i & "]", why): return false
    true
  else:
    if got == want: return true
    why = path & ": expected " & $want & ", got " & $got
    false

proc compareValue(got: JsonNode, c: JsonNode, why: var string): bool =
  let expect = c["expect"]
  if not expect.hasKey("value"):
    why = "expected an error, got " & $got
    return false
  let want = expect["value"]
  case c["compare"].getStr
  of "exact", "json_equal":
    closeTo(got, want, 0.0, "value", why)
  of "float_tol":
    closeTo(got, want, c["tolerance"].getFloat, "value", why)
  else:
    why = "unknown compare mode " & c["compare"].getStr
    false

proc compareError(e: ref PMTilesError, expect: JsonNode, why: var string): bool =
  if e.code.len == 0:
    why = "error without a code"
    return false
  if not expect.hasKey("error"):
    why = "unexpected error " & e.code & " (" & $e.kind & ")"
    return false
  let want = expect["error"]
  let wantKind = want["kind"].getStr
  let wantCode = want["code"].getStr
  if $e.kind != wantKind or e.code != wantCode:
    why = "expected " & wantKind & "/" & wantCode & ", got " & $e.kind & "/" & e.code
    return false
  if want.hasKey("offset"):
    let wantOffset = toU64(want["offset"])
    if e.offset != some(wantOffset):
      why = "expected offset " & $wantOffset & ", got " &
        (if e.offset.isSome: $e.offset.get else: "none")
      return false
  true

proc compareTile(got: Option[seq[byte]], c: JsonNode, why: var string): bool =
  let expect = c["expect"]
  if expect.hasKey("error"):
    why = "expected error " & expect["error"]["code"].getStr & ", got " &
      (if got.isSome: $got.get.len & " bytes" else: "absent")
    return false
  if expect.hasKey("value"):
    if expect["value"].kind != JNull:
      why = "get_tile expects bytes or null, the case has " & $expect["value"]
      return false
    if got.isSome:
      why = "expected absent, got " & $got.get.len & " bytes"
      return false
    return true
  if not expect.hasKey("base64"):
    why = "case has no expected value"
    return false
  let want = toBytes(decode(expect["base64"].getStr))
  if got.isNone:
    why = "expected " & $want.len & " bytes, got absent"
    return false
  if got.get != want:
    why = "expected bytes " & expect["base64"].getStr & ", got " &
      encode(got.get) & " (" & $got.get.len & " bytes)"
    return false
  true

# ---------------------------------------------------------------------------
# Cases

proc limitsOf(c: JsonNode): Limits =
  # `result` starts zeroed, not with the field defaults, so set it explicitly.
  result = Limits()
  if c.hasKey("options"):
    let o = c["options"]
    if o.hasKey("max_directory_entries"):
      result.maxDirectoryEntries = toU64(o["max_directory_entries"])
    if o.hasKey("max_directory_bytes"):
      result.maxDirectoryBytes = toU64(o["max_directory_bytes"])
    if o.hasKey("max_leaf_depth"):
      result.maxLeafDepth = toU32(o["max_leaf_depth"])
    if o.hasKey("max_metadata_bytes"):
      result.maxMetadataBytes = toU64(o["max_metadata_bytes"])

type Outcome = object
  ## One run of an io operation, so the file and memory sources can be compared.
  err: ref PMTilesError
  tile: Option[seq[byte]]
  text: string

proc same(a, b: Outcome): bool =
  if (a.err == nil) != (b.err == nil): return false
  if a.err != nil: return a.err.code == b.err.code and a.err.kind == b.err.kind
  a.tile == b.tile and a.text == b.text

proc runIo(c: JsonNode, src: Source, limits: Limits): Outcome =
  try:
    case c["op"].getStr
    of "get_tile": result.tile = getTile(src, toCoord(c["input"]["args"]["coord"]), limits)
    of "read_metadata": result.text = readMetadata(src, limits)
    else: raise bad("not an io op")
  except PMTilesError as e:
    result.err = e

proc runCase(c: JsonNode, casesDir: string, why: var string): bool =
  let op = c["op"].getStr
  let input = c["input"]
  let expect = c["expect"]
  let limits = limitsOf(c)
  case op
  of "decode_header":
    var h: Header
    try:
      h = decodeHeader(inputBytes(input, casesDir))
    except PMTilesError as e:
      return compareError(e, expect, why)
    compareValue(toJson(h), c, why)
  of "decode_directory":
    var entries: seq[Entry]
    try:
      entries = decodeDirectory(inputBytes(input, casesDir), limits)
    except PMTilesError as e:
      return compareError(e, expect, why)
    var got = newJArray()
    for e in entries: got.add toJson(e)
    compareValue(got, c, why)
  of "zxy_to_tile_id":
    var id: uint64
    try:
      id = zxyToTileId(toCoord(input["value"]))
    except PMTilesError as e:
      return compareError(e, expect, why)
    compareValue(u64Json(id), c, why)
  of "tile_id_to_zxy":
    var coord: TileCoord
    try:
      coord = tileIdToZxy(toU64(input["value"]))
    except PMTilesError as e:
      return compareError(e, expect, why)
    compareValue(toJson(coord), c, why)
  of "find_entry":
    var entries: seq[Entry]
    for e in input["value"]["entries"].getElems: entries.add toEntry(e)
    let found = findEntry(entries, toU64(input["value"]["tile_id"]))
    compareValue(if found.isSome: toJson(found.get) else: newJNull(), c, why)
  of "get_tile", "read_metadata":
    let path = casesDir / input["file"].getStr
    var viaFile: Outcome
    try:
      viaFile = runIo(c, fileSource(path), limits)
    except PMTilesError as e:
      viaFile.err = e
    let viaMemory = runIo(c, memorySource(toBytes(readFile(path))), limits)
    if not same(viaFile, viaMemory):
      why = "file and memory sources disagree"
      return false
    if viaFile.err != nil:
      return compareError(viaFile.err, expect, why)
    if op == "get_tile": compareTile(viaFile.tile, c, why)
    else: compareValue(newJString(viaFile.text), c, why)
  else:
    why = "unknown op " & op
    false

proc main(): int =
  let path =
    if paramCount() >= 1: paramStr(1)
    else: currentSourcePath().parentDir.parentDir / ".spec" / "conformance" / "manifest.json"
  let casesDir = path.parentDir / "cases"
  let manifest = parseFile(path)
  let specVersion = manifest["spec_version"].getStr

  var corePassed, coreTotal, ioPassed, ioTotal, fullPassed, fullTotal = 0
  for c in manifest["cases"].getElems:
    let level = c{"level"}.getStr("core")
    var why = ""
    var ok = false
    try:
      ok = runCase(c, casesDir, why)
    except CatchableError as e:
      why = "runner error: " & e.msg
    if not ok:
      echo "FAIL ", c["id"].getStr, ": ", why
    # Every case counts toward full; core and io cases toward their own level.
    inc fullTotal
    if ok: inc fullPassed
    if level == "core":
      inc coreTotal
      if ok: inc corePassed
    elif level == "io":
      inc ioTotal
      if ok: inc ioPassed
  echo "pmtiles nim (spec ", specVersion, "): core ", corePassed, "/", coreTotal,
    ", io ", ioPassed, "/", ioTotal, ", full ", fullPassed, "/", fullTotal
  if fullPassed != fullTotal: 1 else: 0

when isMainModule:
  quit main()
