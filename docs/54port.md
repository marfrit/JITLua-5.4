# Lua 5.4 semantic delta — checklist → test map (MISSION §4)

Status: Phase 0 (M0). Every box below has at least one differential test.
Tests **print** behavior; the harness compares PUC-Lua 5.4.7 (oracle) vs our
interpreter (`-joff`, mode A) and our JIT (`-jon`, mode B), plus dump/reload (mode R).
Run: `tests/harness.sh --mode all`. Expected failures: `tests/known-bad.tsv`.

## §4.1 numeric model
| item | test |
|---|---|
| int/float types, `math.type`, wrap, `math.maxinteger/mininteger` | `tests/d54/numeric_01_types.lua` |
| `+ - * /` int/float/mixed, `/` always float, string coercion | `numeric_02_arith.lua` |
| `//` floor division (int/float/mixed, `INT64_MIN // -1`) | `numeric_03_idiv.lua` |
| `%` sign rules, `math.fmod` contrast | `numeric_04_mod.lua` |
| `^` always float, unary minus | `numeric_01_types.lua`, `numeric_02_arith.lua` |
| bitwise `& \| ~ << >>`, precedence, logical `>>`, mod-64/negative counts | `bits_01_ops.lua` |
| `__band/__bor/__bxor/__shl/__shr/__bnot` dispatch | `bits_02_metamethods.lua` |
| `__add/__sub/__mul/__div/__mod/__pow` operand matrix (5 kinds × 6 ops × 2 orders) | `meta_01_matrix.lua` |
| `__idiv` + bitwise matrix | `bits_02_metamethods.lua`, `numeric_03_idiv.lua` |
| `__eq/__lt/__le`, exact int↔float comparison | `meta_02_compare_len.lua` |
| int↔float conversion, `math.tointeger`, 2^53 boundaries | `numeric_01_types.lua`, `numeric_02_arith.lua`, `math_os_01.lua` |
| `tonumber` (bases, hex, hex-float, whitespace, invalid) | `lex_01_literals.lua` |
| `math` 5.4 split (`type/tointeger/ult`, mixed max/min, random) | `math_os_01.lua` |

## §4.2 language / libraries
| item | test |
|---|---|
| literals: hex, hex floats, overflow→float, malformed | `lex_01_literals.lua` |
| `goto`/`::label::` 5.4 scoping | `goto_01_labels.lua` |
| vararg `#...`, `select`, forwarding, holes | `tbl_01_lib.lua` |
| `string.format` `%d/%x/%o/%i/%a/%g/%q` rules | `fmt_01_format.lua` |
| float rendering (`tostring`, `%.14g`) | `fmt_01_format.lua` |
| `string.rep/sub/find/gmatch/gsub/byte/char` | `dump_str_01.lua` |
| `string.pack/unpack/packsize` | `str_02_pack.lua` |
| `table.move/pack/unpack(i,j)/concat/insert/remove/sort`, `#` borders | `tbl_01_lib.lua` |
| `__len` any value; `__pairs`/`__ipairs` absent | `meta_02_compare_len.lua` |
| `utf8` library | `utf8_01_lib.lua` |
| `coroutine.close`, resume/yield errors, `isyieldable` | `coro_01_close.lua` |
| `<close>`/`<const>` attributives, `__close` order | `gc_01_tbc_gc.lua`, `coro_01_close.lua` |
| `os.time(table)`, `os.date`, `os.difftime` (TZ=UTC) | `math_os_01.lua` |
| `error(level)`, non-string error objects, `xpcall` | `err_01_xpcall.lua` |
| `_ENV`; `getfenv/setfenv` kept as LuaJIT extensions | `env_01_fenv.lua` |

## §4.3 VM / bytecode / C API (partial in M0)
| item | test |
|---|---|
| `string.dump` round-trip, `strip` flag, header bytes | `dump_str_01.lua`, harness mode R (all tests) |
| 5.4 opcode set, EXTRAARG int constants, `luac -l` cross-check | Phase 1 (open question §10.1) |
| C API surface (`luaL_len`, `lua_stringtonumber`, `lua_gc` actions, …) | Phase 1 — needs a C-side test harness |

## §4.4 GC
| item | test |
|---|---|
| `collectgarbage` generational/incremental/step/pause | `gc_01_tbc_gc.lua` |
| weak tables (k/v), `__gc`, cycles, resurrection | `gc_01_tbc_gc.lua` |
| GC-pressure fuzzing | `tests/fuzz/fuzz.py --gc` |

## MISSION errata (verified against PUC-Lua 5.4.7)
Details and probe results: `docs/phase0-status.md`. Summary: no underscore
separators, no `0b` literals, `table.create` is not PUC 5.4, `%g`/`tostring` use
`%.14g` (not shortest round-trip), bitwise accepts exactly-representable floats,
negative shift counts reverse direction (no error), int→float rounds (does not
truncate), `v2.1` is a branch not a tag.
**`__pairs` DOES exist in 5.4.7** (it is honored); `__ipairs` does not. MISSION
4.2's claim that both were removed is wrong — implemented accordingly.

## Implemented since M0 (see git log for the labeled commits)
utf8 lib · `\u{}` to 0x7FFFFFFF · NUL-aware patterns · gmatch 5.4 lastmatch rule ·
`%d/%x/...` integer-representation rule · `%q` literal forms · library error-name
resolution · goto/label 5.4 diagnostics · `<const>` attributives · int/float
literal split (scanner, parser float-constant table, fold rules, JIT recorder) ·
5.4 `.0` float rendering (tostring/concat/table.concat, interp+JIT) ·
math.type/tointeger/ult · os.time/date/difftime/rename · io.write/open/lines ·
math.random 5.4 (xoshiro256**, seed-exact with PUC) · dual-number mode forced on
x64/x86 (`-DLUAJIT_NUMMODE=2`, otherwise those targets have no integer type) ·
tonumber 5.4 rules · debug.upvalueid/upvaluejoin · table borders + rawlen ·
`__len` on tables (any value) · `__pairs` · `__name` type names ·
C API: absindex, isinteger, geti/seti, len, compare, stringtonumber, rotate,
luaL_len, luaL_getsubtable (34-check C harness).

## Fuzzing
`tests/fuzz/gen.py` (seeded, valid 5.4, deterministic) + `tests/fuzz/fuzz.py`
(modes A/B/R, `--opt-levels`, `--gc`, saves failing seeds under
`tests/fuzz/failures/`). M0 smoke: 240/240 mode-B runs green at opt levels 0–3
with GC pressure; mode A fails on every program (unported 2.1, as expected).
M3 gate: ≥10M programs, 0 failures.
