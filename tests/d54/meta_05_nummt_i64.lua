--! PENDING (ADR-001b boxed int64): PUC keeps one number-metatable slot that
--! int and float share (PUC src/lstate.h global_State.mt[LUA_NUMTYPES];
--! src/ltm.c luaT_gettmbyobj indexes by the number type), so
--! debug.setmetatable(0, mt) applies to every number, including integers
--! outside the 32-bit range, and getmetatable of such an integer returns
--! mt. LuaJIT keeps one base metatable per value tag (src/lj_api.c
--! lua_setmetatable, basemt_obj): a value that is not number-tagged --
--! specifically a boxed int64 (UDTYPE_I64BOX userdata, src/lj_obj.h
--! tvisi64) -- does not get the number metatable, and getmetatable of it
--! returns nil. 47-bit inline integers (i47run) share the number tag and
--! work; integer literals above int32 are materialized as boxes even when
--! the value fits in 47 bits (i47lit), so they behave like i64.
local mt = { __index = math }
debug.setmetatable(0, mt)
print("small", (1):floor())
local i47run = (1 << 45) + 3   -- 35184372088835, 47-bit inline
local i47lit = 35184372088835  -- same value, literal
local i64 = (1 << 50) + 3      -- 1125899906842699, boxes on both sides' model
print("i47run ok", pcall(function() return i47run:floor() end))
print("i47run mt", getmetatable(i47run) == mt)
print("i47lit ok", pcall(function() return i47lit:floor() end))
print("i47lit mt", getmetatable(i47lit) == mt)
print("i64 ok", pcall(function() return i64:floor() end))
print("i64 mt", getmetatable(i64) == mt)
debug.setmetatable(0, nil)
print("cleared", getmetatable(1) == nil)
