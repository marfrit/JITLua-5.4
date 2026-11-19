-- Driver for tests/capi/headers_probe.c (built as a loadable module).
-- Asserts the public-header values the C module read back, so a header that
-- stops pulling in <limits.h>, drops lua_numbertointeger, or loses a 5.4
-- constant fails here instead of in a third-party module.
local p = require "headers_probe"
local c = assert(p.constants(), "constants() must return a table")

assert(c.maxinteger > 0, "LUA_MAXINTEGER must be positive")
assert(c.mininteger < 0, "LUA_MININTEGER must be negative")
assert(c.maxinteger >= c.int_max, "LUA_MAXINTEGER must cover INT_MAX")
assert(c.maxunsigned_wraps == true, "LUA_MAXUNSIGNED must be the all-ones mask")
assert(c.int_max > 0, "INT_MAX must come from <limits.h> transitively")
assert(c.long_max > 0, "LONG_MAX must come from <limits.h> transitively")
assert(type(c.maxstack) == "number" and c.maxstack > 0, "LUAI_MAXSTACK")
assert(c.idsize == 60, "LUA_IDSIZE must be 60")
assert(c.bufsize > 0, "LUAL_BUFFERSIZE")
assert(c.numsizes > 0, "LUAL_NUMSIZES")
assert(c.numtypes == 9, "LUA_NUMTYPES must be 9")
assert(c.gname == "_G", "LUA_GNAME")
assert(c.preload == "_PRELOAD", "LUA_PRELOAD_TABLE")
assert(c.likely == true, "luai_likely/luai_unlikely")
assert(c.kctx_zero == true, "LUA_KCONTEXT must be usable as a zero value")
assert(p.sane_limits == true, "LUA_MAXINTEGER/LUA_MININTEGER constants")

assert(p.numbertointeger(42) == 42, "lua_numbertointeger(42)")
assert(p.numbertointeger(-7) == -7, "lua_numbertointeger(-7)")
-- The macro range-checks only; callers pre-check integrality.  A non-integral
-- value in range converts by truncation, exactly like PUC's macro.
assert(p.numbertointeger(2.5) == 2, "lua_numbertointeger(2.5) truncates")
assert(p.numbertointeger(-2.5) == -2, "lua_numbertointeger(-2.5) truncates")
assert(p.numbertointeger(1e300) == nil, "lua_numbertointeger(1e300) must fail")
assert(p.numbertointeger(-1e300) == nil, "lua_numbertointeger(-1e300) must fail")

print("headers_probe: OK maxinteger=" .. c.maxinteger ..
      " int_max=" .. c.int_max .. " numtypes=" .. c.numtypes)
