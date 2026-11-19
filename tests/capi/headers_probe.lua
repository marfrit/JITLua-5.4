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

-- The conversion macros, expanded in the module.
local v = assert(p.conversions(), "conversions() must return a table")
assert(v.integer2str == "-1234567890123", "lua_integer2str: " .. tostring(v.integer2str))
assert(v.integer2str_bounded == true, "lua_integer2str must honour the buffer size")
assert(v.number2str == "0.5", "lua_number2str: " .. tostring(v.number2str))
assert(v.number2str_bounded == true, "lua_number2str must honour the buffer size")
assert(v.number2strx == "1.500", "lua_number2strx: " .. tostring(v.number2strx))
assert(v.pointer2str == true, "lua_pointer2str")
assert(v.str2number == 2.25 and v.str2number_end == "rest", "lua_str2number")
assert(v.strx2number == 16, "lua_strx2number")
assert(v.decpoint == ".", "lua_getlocaledecpoint in the C locale")

-- luaL_checkversion_: silent for a matching module, an error otherwise.
assert(pcall(p.checkversion), "luaL_checkversion must accept this module")
local ok, msg = pcall(p.checkversion, 503)
assert(not ok and msg:find("version mismatch", 1, true),
       "luaL_checkversion_ must reject another version: " .. tostring(msg))
ok, msg = pcall(p.checkversion, 504, 1)
assert(not ok and msg:find("incompatible numeric types", 1, true),
       "luaL_checkversion_ must reject other numeric type sizes: " .. tostring(msg))

-- The stamp is PUC's own value: the corpus fixtures (tests/corpus/puc54/libs)
-- are compiled against PUC's headers and loaded by both interpreters.
assert(c.numsizes == p.puc_numsizes, "LUAL_NUMSIZES must have PUC 5.4's value")
assert(pcall(p.checkversion, 504, p.puc_numsizes))

print("headers_probe: OK maxinteger=" .. c.maxinteger ..
      " int_max=" .. c.int_max .. " numtypes=" .. c.numtypes)
