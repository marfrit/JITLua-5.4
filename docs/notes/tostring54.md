# __tostring must return a string (branch `tostring54`)

Base: main `f8c70a23`. The tests are `tests/d54/tostring_01_return.lua` ..
`tostring_04_errhandler.lua` and the `tolstring` group in
`tests/capi/test_capi.c`; `tests/bench/b6_tostring.lua` measures the hot path.

## What PUC 5.4.9 does

`luaL_tolstring` (lauxlib.c) is the one conversion routine:

```c
if (luaL_callmeta(L, idx, "__tostring")) {
  if (!lua_isstring(L, -1))     /* string or number; a number is converted */
    luaL_error(L, "'__tostring' must return a string");
} else switch (lua_type(L, idx)) {
  ... TABLE/USERDATA/... default:
    int tt = luaL_getmetafield(L, idx, "__name");
    const char *kind = (tt == LUA_TSTRING) ? lua_tostring(L, -1) : luaL_typename(L, idx);
    lua_pushfstring(L, "%s: %p", kind, lua_topointer(L, idx));
```

Paths that call it: `tostring()` (lbaselib luaB_tostring), `print()` (5.4.9
luaB_print, one `luaL_tolstring` per argument, not a replaced global
`tostring`), `string.format("%s")` (lstrlib `case 's': luaL_tolstring`), the
C API `luaL_tolstring` itself. `table.concat` does **not**: `addfield` uses
`lua_isstring` and reports `invalid value (TABLE) at index N in table for
'concat'`; the `..` operator does not either (it only calls `__concat`).

The standalone message handler (lua.c msghandler) is separate: it calls
`__tostring` for a non-string error object and uses the result only when
`lua_type == LUA_TSTRING`; otherwise it reports
`(error object is a TABLE value)` and appends the traceback.

## Paths before and after

| path | before | after |
|---|---|---|
| `tostring(x)` (C fast function) | tail-called `__tostring`, returned its value unchanged | normal call, `lj_strfmt_tolstrres` checks/converts |
| `tostring(x)` in a trace | recorder tail-called the metamethod, result type unchecked | recorder leaves the call to the interpreter (stitch / exit) |
| `tostring(x)` VM asm fast path | string inline even with a string base metatable `__tostring`; number inline unless a number base metatable exists | string falls back when the string base metatable has `__tostring` |
| `tostring(plain)` | `lj_strfmt_obj`, no `__name` | `lj_strfmt_obj` with the metatable's string `__name` |
| `print(x)` | called the global `tostring`, `'tostring' must return a string to 'print'` | PUC 5.4.9 shape: `luaL_tolstring` per argument |
| `string.format("%s", x)` | called `__tostring`, then rendered whatever came back | `lj_strfmt_tolstrres`; a number converts, others raise |
| `string.format("%s", str)` | never looked at the string metatable | calls a `__tostring` in the string metatable (one test of the negative cache bit otherwise); `%q` does not, as in PUC |
| `luaL_tolstring` | already PUC-shaped, but `luaL_getmetafield` returned a boolean so the `__name` branch never fired | `luaL_getmetafield` returns the field type |
| standalone handler | accepted a number result, printed `42` | PUC's `lua_type(...) == LUA_TSTRING` rule |

One helper holds the rule for the new paths: `lj_strfmt_tolstrres()` in
`lj_strfmt.c` — string passes, number/int64 converts with the 5.4 number
format, everything else raises `"'__tostring' must return a string"`
(`LJ_ERR_TOLSTR`, replacing the now unused `LJ_ERR_PRTOSTR`). Buffers are
userdata in LuaJIT and, like `lua_isstring`, not accepted. `luaL_tolstring`
keeps its PUC-verbatim `lua_isstring` check.

`__name` is looked up the way `lj_meta_lookup` looks up a metamethod:
metatable of a table/userdata, otherwise the per-type base metatable, so
function, thread and light-userdata metatables (`debug.setmetatable`) work.
Long names are built in a heap `SBuf`, not the global temporary buffer, since
`lj_strfmt_obj` can be called while `string.format` already owns that buffer.

## The asm string path and the negative cache

The string base metatable exists in LuaJIT (it holds the string library), so
the asm cannot use "metatable present" as the number path does. `GCtab.nomm`
only caches the fast metamethods (bits 0..MM_FAST); `__tostring` is not one.
Spare bit 6 is now `MM_TOSTR_ABSENT`: `lj_meta_lookup` sets it on a
`__tostring` miss, and any string-keyed store into a metatable clears the
whole byte (`lj_tab_set`, the interpreter's TSETS, and the store compiled
code emits for a key `nommstr` reports: the fast metamethod names and, since
the review fix, `__tostring`). The asm inlines a string only when the bit is set; otherwise it calls
the C fallback, which performs the real lookup and either calls the metamethod
or fills the bit. The first `tostring(string)` per process pays one lookup.

x64 and arm64 have this check; the other interpreters keep the old inline
behaviour (they are not gated here; same status as the other 5.4-only paths).

## Benchmark (x64, one box, base `f8c70a23` and head interleaved, 7 rounds)

`tests/bench/b6_tostring.lua`, N = 2,000,000, medians in ms:

| case | -joff base | -joff head | -jon base | -jon head |
|---|---|---|---|---|
| `tostring(integer)` | 421 | 420 | 354 | 353 |
| `tostring("abc")` | 60 | 60 | 2 | 2 |
| `tostring(obj.__tostring -> "abc")` | 122 | 149 | 2.4 | 182 |
| `string.format("%s", integer)` | 623 | 630 | 608 | 620 |

The no-metamethod hot paths are flat (num/str within noise, `format` +1..2 %
from code layout). The `__tostring` case costs +23 % in the interpreter (a
normal call instead of a tail call plus the result check) and is no longer
traced under `-jon` (91 ns/call instead of 1.2 ns). That is the deliberate
price of the result check: a trace cannot validate a tail-called metamethod's
result type. A follow-up could keep the trace when the recorded metamethod
necessarily returns a string by guarding at the tail-call return point; the
recorder currently exits to the interpreter for every `__tostring`, which is
the correct and simple route.

## Counter-check

`tostring(print)` keeps LuaJIT's `builtin#N` rendering (an inherited
extension, not a 5.4 difference in a conversion path); with a `__name` on the
function type metatable it becomes `NAME: builtin#N` instead of PUC's
`NAME: 0x...`. No test depends on it. `%q` on nil/boolean still goes through
`lj_strfmt_obj` and ignores a per-type `__tostring`, which PUC's `addliteral`
would call through `luaL_tolstring`; left as-is (not in the task's path list).

## Gates (both architectures)

`sh tests/ci-box.sh`: all stages passed. `tests/ci-local.sh
--sanitizers-only`: OK. Full strict corpus (`tests/harness.sh --mode all
--strict`, the CI command): 382 PASS / 0 FAIL / 8 XFAIL / 12 SKIP. d54:
A+B 212 PASS / 0 FAIL / 4 XFAIL, opt levels 0-3 468, R 114, ASan/UBSan A+B+R
326. C API 258 + 92 + 18, 0 failures.

## Remaining risks

- Closed by the review fix: a trace that inlined `tostring(string)`,
  `tostring(number)` or `tostring(nil/boolean)` did not notice a `__tostring`
  stored into the type's metatable afterwards, because the recorder looked
  the method up without recording the lookup. `recff_tostring` and the `%s`
  case of the `string.format` recorder now record it with
  `lj_record_mm_lookup`, like every other metamethod lookup: a guard on the
  absent field when the metatable exists (always, for strings), nothing when
  the type has no metatable (`lua_setmetatable` flushes the traces when one
  is installed). `tests/d54/tostring_05_late_mm.lua`.
- `tostring` called recursively from its own `__tostring` ends in
  "stack overflow" (the Lua stack limit) where PUC reports "C stack
  overflow"; no crash on either architecture.
- A `__name` longer than the stack buffer is assembled in a heap `SBuf`. If
  the string allocation that follows fails with a memory error, that buffer
  is not freed until the state is closed.
- `__tostring` that yields: the C fast function now uses `lua_call`, so the
  yield stops at the C-call boundary like PUC. The old tail call handed the
  metamethod the fast function's frame; whether a yield could cross it there
  was not covered by a test.
- An FFI cdata value has `__tostring` in its per-type base metatable
  (`ffi_meta`), so `tostring(cdata)` now leaves the trace to the interpreter
  like every other value with a metamethod. Output is unchanged (a ctype
  `__tostring` still tail-calls inside `ffi_meta___tostring`).
