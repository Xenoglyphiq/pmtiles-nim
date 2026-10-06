# PMTiles for Nim

Read PMTiles v3 single-file tile archives: header, directories, tile lookup and tile bytes, from memory, a local file or HTTP range requests. Implements PMTiles v3 (read only) · Spec v0.1.1 · Conformance: **core ✓ io ✓ full ✓** (68/68)

> **Tile bytes are returned as stored.** `getTile` gives you the tile still compressed with `header.tileCompression` and doesn't parse it. Decoding MVT, PNG or other contents is up to you.

Requires Nim **2.2.12** on the C backend (the JS backend is untested). Depends on [zippy](https://github.com/guzba/zippy) (pure Nim) for gzip.

## Install

> Listing in the Nimble directory (`nimble install pmtiles`) is pending; until it lands, install by URL as below.

```
nimble install https://github.com/Xenoglyphiq/pmtiles-nim@#v0.1.0
```

Or in your `.nimble` file:

```nim
requires "https://github.com/Xenoglyphiq/pmtiles-nim#v0.1.0"
```

## Quick start

```nim
import pmtiles/io

let src = fileSource("tiles.pmtiles")
let tile = getTile(src, TileCoord(z: 2, x: 1, y: 3))
if tile.isSome:
  echo tile.get.len, " bytes"
echo readMetadata(src)
```

## Examples

Run all three with `nimble examples`. The third needs network access.

### 1. Print an archive's header (`examples/inspect_archive.nim`)
```nim
let h = decodeHeader(head) # the first 127 bytes of the file
echo "zooms ", h.minZoom, "-", h.maxZoom
echo "bounds lon ", h.bounds.minLon, " to ", h.bounds.maxLon,
  ", lat ", h.bounds.minLat, " to ", h.bounds.maxLat
echo "tile type ", h.tileType
```

### 2. Fetch one tile by z/x/y (`examples/fetch_one_tile.nim`)
```nim
let tile = getTile(fileSource(path), TileCoord(z: 2, x: 1, y: 3))
if tile.isSome: echo tile.get.len, " bytes"
else: echo "not found"
```

### 3. Read metadata over HTTP (`examples/remote_metadata.nim`)
```nim
echo readMetadata(httpSource("https://pmtiles.io/protomaps(vector)ODbL_firenze.pmtiles"))
```
Build with `-d:ssl` for `https` URLs.

## API

| Proc | Spec operation | Module |
|---|---|---|
| `decodeHeader(data): Header` | `decode_header` | `pmtiles` |
| `decodeDirectory(data, limits): seq[Entry]` (input already decompressed) | `decode_directory` | `pmtiles` |
| `zxyToTileId(coord): uint64` | `zxy_to_tile_id` | `pmtiles` |
| `tileIdToZxy(tileId): TileCoord` | `tile_id_to_zxy` | `pmtiles` |
| `findEntry(entries, tileId): Option[Entry]` | `find_entry` | `pmtiles` |
| `getTile(src, coord, limits): Option[seq[byte]]` | `get_tile` | `pmtiles/io` |
| `readMetadata(src, limits): string` (unparsed JSON) | `read_metadata` | `pmtiles/io` |

`Compression` and `TileType` are open enums: an object with a `kind` and the `raw` byte. Values outside the spec's table have kind `ckUnknownValue` / `ttUnknownValue` and keep their raw byte; `$` prints them as `unknown(raw)`. Header counts stored as 0 are `none`.

### Sources

| Source | Backed by |
|---|---|
| `memorySource(data)` | a `seq[byte]` already in memory |
| `fileSource(path)` | a local file, read with positioned reads; closed when the source goes out of scope |
| `httpSource(url)` | `std/httpclient` `Range` requests, sent with `Accept-Encoding: identity`; servers that ignore `Range` still work |
| `newSource(readRange)` | your own `proc (offset, length: uint64): seq[byte]` |

A source returns up to `length` bytes; fewer means the archive ends there, which the operations report as `pmtiles.truncated`. A failed read raises `pmtiles.source_failed`.

### Internal compression

| Compression | Supported |
|---|---|
| `none` | yes |
| `gzip` | yes (zippy) |
| `brotli`, `zstd` | no: `pmtiles.unsupported_compression` |
| `unknown`, unknown raw values | no: `pmtiles.unsupported_compression` |

A gzip stream that doesn't decompress is `pmtiles.invalid_directory` for a directory and `pmtiles.truncated` for the metadata.

## Limits and errors

| Limit | Default | Option name |
|---|---|---|
| Entries in one directory | 1,000,000 | `Limits.maxDirectoryEntries` |
| Bytes fetched for one directory | 16 MiB | `Limits.maxDirectoryBytes` |
| Leaf directories followed (root is depth 0) | 4 | `Limits.maxLeafDepth` |
| Bytes fetched for the metadata | 16 MiB | `Limits.maxMetadataBytes` |

Pass limits as `limits = Limits(maxLeafDepth: 1)`; fields you leave out keep their defaults.

Errors are `PMTilesError` (a `CatchableError`) with a `kind` (`ekInvalidInput`, `ekUnsupported`, `ekLimitExceeded` or `ekIo`; `$kind` gives the spec names), a stable `code` such as `pmtiles.bad_magic`, and the byte `offset: Option[uint64]` where known (`decodeDirectory` reports the varint that failed). Full list: spec §3.

Every public proc is annotated `{.raises: [PMTilesError].}` (or raises nothing). Sums of ids and offsets are checked before they're computed, so no `OverflowDefect` or `RangeDefect` escapes. A missing tile is `none`, not an error.

## Modules

| Module | Layer | Needs |
|---|---|---|
| `pmtiles` | core | nothing beyond the standard library |
| `pmtiles/io` | io | zippy; `std/httpclient` (`-d:ssl` for https) |

`pmtiles/io` re-exports `pmtiles`.

## Development

| Command | What |
|---|---|
| `nimble test` | Unit tests and the conformance runner |
| `nimble conformance` | Every case in `.spec/conformance/manifest.json` |
| `nimble examples` | The three canonical examples |
| `FUZZ_SECONDS=600 nimble fuzz` | Mutation-fuzz the decoders and `getTile` (`FUZZ_SEED` replays a run) |
| `nimble bench` | `getTile` timings on `.spec/bench/` (`-d:release`; `BENCH_DIR` overrides the directory) |

## Performance

| Benchmark | Reference | This port | Ratio |
|---|---|---|---|
| `get_tile`, stateless | Rust `pmtiles` 0.24.1: 165.1 ms | 222.8 ms | 1.35× |

Median per pass of 10,000 lookups from memory, method in `.spec/bench/README.md`. Recorded 2026-10-06 on an Apple M5 Pro, interleaved with the reference in one session (median of three rounds). Nim 2.2.12, `-d:release`.

## License

MIT OR Apache-2.0
