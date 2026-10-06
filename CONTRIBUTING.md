# Contributing to PMTiles for Nim

Thanks for helping. This package is one of several language ports of the same spec, and all of them must behave identically.

## How this repo works

- The package itself lives at the repo root, laid out the way Nim expects: `pmtiles.nimble`, the core module `src/pmtiles.nim` and the io module `src/pmtiles/io.nim`. The conformance runner is `tests/tconformance.nim`, and the fuzzer is `tests/fuzz.nim`.
- **`.spec/`** is a copy of the spec and its conformance cases from **`Xenoglyphiq/pmtiles-spec`**, at the version in `.spec/SPEC_VERSION`. Don't edit it here; it's replaced when the port moves to a newer spec.
- **`.kit/`** holds shared conventions, schemas and the validator. Don't edit it here either.

Read `.kit/CONVENTIONS.md` and `.spec/spec/SPEC.md` before changing behavior.

## Where to send a change

| You want to… | Where |
|---|---|
| Fix a bug in this port | Here. Add a test or point to the conformance case it fixes |
| Change how the library behaves | The spec repo `Xenoglyphiq/pmtiles-spec`. Open an issue there first |
| Report that this port behaves differently from another | The spec repo, with the input; it becomes a conformance case |
| Improve docs or examples for this port | Here |

## Checks every PR must pass

1. `python .kit/validate.py .spec` (needs `pip install pyyaml jsonschema`)
2. Build and unit tests: `nimble test`, plus `nim check src/pmtiles.nim` and `nim check src/pmtiles/io.nim` with no warnings
3. Conformance runner: `nimble conformance`; every claimed level must pass
4. The three canonical examples: `nimble examples`
5. A short fuzz run: `FUZZ_SECONDS=30 nimble fuzz`

## Style

- Follow Nim's own conventions for names, errors and packaging.
- Errors keep the kinds and codes from the spec; tests assert kind and code, never message text.
- Every public item has a doc comment naming the spec operation it implements.
- Public procs stay `{.raises: [PMTilesError].}`. The core module never does I/O and depends only on the standard library.
- Guard every sum of ids or offsets and every narrowing conversion by hand. Nim checks neither unsigned arithmetic nor conversions between unsigned types, so the directory decoder repeats those guards as assertions in checked builds (`-d:pmtilesChecked`, set for tests and the fuzzer).
- The directory decoder is the hot loop: it doesn't raise or build strings. It records a failure built from literals and the public proc raises once.

## License

By contributing you agree your contribution is licensed under MIT OR Apache-2.0, the same as this project.
