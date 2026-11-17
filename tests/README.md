# tests/ — LuaJIT-5.4 verification harness

Mission rule: **the interpreter is the oracle, PUC-Lua 5.4.7 is the oracle's
oracle.** No phase is done until `tests/harness.sh` is green in both modes.

## Quick start
```sh
make -j8                      # build our LuaJIT (src/luajit)
tests/ref/fetch-ref.sh        # build PUC-Lua 5.4.7 (tests/ref/bin/lua54ref)
tests/harness.sh              # modes A + B over the whole corpus
tests/harness.sh --mode all   # + mode R (string.dump -> load -> re-run)
```

## Modes
| mode | comparison | proves |
|---|---|---|
| A | `lua54ref` vs `luajit -joff` | our interpreter implements 5.4 |
| B | `luajit -jon` vs `luajit -joff` | the JIT matches our interpreter |
| R | direct run vs `lib/dump_reload.lua` | the serializer round-trips |

`--opt-levels 0,1,2,3` runs mode B once per JIT optimization level (`-O<n>`).
Note LuaJIT's CLI is `-joff`/`-jon`, not `--jit=off`.

## Useful invocations
```sh
tests/harness.sh --filter 'd54/numeric*' --verbose
tests/harness.sh --mode B --opt-levels 0,1,2,3 --corpus tests/d54
tests/harness.sh --mode all --timeout 120 --strict      # XPASS becomes fatal
tests/harness.sh --update-known-bad                     # refresh expected failures
tests/harness.sh --list
LUAJIT=tests/ref/sanbuild/src/luajit tests/harness.sh --corpus tests/d54
```

## Statuses
`PASS` / `FAIL` (unexpected, exit 1) / `XFAIL` (listed in `known-bad.tsv`) /
`XPASS` (listed but now passing — remove the entry) / `SKIP` (directive, or PUC
`T.*` internal test hooks) / `BAD` (corpus file is not valid Lua 5.4 — fix the
test) / `TIMEOUT` (both sides exceeded the limit; counts as a failure of the run unless a
known-bad entry covers the file and mode, then it is reported as `XFAIL`).

Every corpus file is pre-flighted with `luac54ref -p`; a file that fails to parse
on the reference would otherwise "pass" mode A by failing on both sides.

## Layout
- `harness.sh`, `lib/runner.py` — runner; `lib/dump_reload.lua` — mode R wrapper.
- `d54/` — our 5.4 edge-case corpus (see `docs/54port.md` for the §4 → test map).
- `corpus/puc54/` — vendored upstream `testes/` (Lua 5.4.7), unmodified.
- `ref/` — pinned reference fetch/build (`manifest.txt`), binaries are artifacts.
- `fuzz/` — `gen.py` (seeded valid-5.4 generator), `fuzz.py` (differential driver).
- `known-bad.tsv` — `test<TAB>modes<TAB>reason`; the M0 baseline of unported 2.1.
- `report/last.{json,md}` — generated reports (gitignored).
- `ci-local.sh` — normal + ASan/UBSan builds, harness, short fuzz.

## Test-writing rules
1. Tests **print** behavior; they do not assert expected values (the oracle
   decides). A few `assert()`s encode invariants that must hold everywhere.
2. Deterministic: no `io`, no clock, no unseeded randomness, no addresses.
   The harness forces `TZ=UTC`, `LC_ALL=C` and isolated `LUA_PATH`/`LUA_CPATH`.
3. Keep 5.4-only syntax (`//`, bitwise, `<close>`) in separate files or inside
   `load([[...]])`, so 5.1-parseable files yield semantic diffs, not parse errors.
4. Directives: `--! skip: reason`, `--! modes: A,B`, `--! timeout: N`,
   `--! args: ...`, `--! no-parse-check:`.
5. New semantics land with a test **before** the code (MISSION §7.2).

## Fuzzing
```sh
python3 tests/fuzz/fuzz.py --seed 1 --count 500 --mode B --opt-levels 0,1,2,3 --gc
python3 tests/fuzz/fuzz.py --seed 1 --count 200 --mode R --gc
python3 tests/fuzz/fuzz.py --seed 9000 --count 100 --mode A     # vs PUC 5.4.7
```
Programs are generated from `seed + n`, so any failure is reproducible; the
driver saves program, both outputs, the diff and a repro command under
`tests/fuzz/failures/`. Commit failing seeds (MISSION §7.3). M3 gate: ≥10M
programs with zero failures.
