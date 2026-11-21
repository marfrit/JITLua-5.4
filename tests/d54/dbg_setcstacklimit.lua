--! §4.6 debug.setcstacklimit is kept in PUC 5.4.9 for compatibility
--! (ldblib.c db_setcstacklimit): it checks its argument with
--! luaL_checkinteger and returns what lua_setcstacklimit returns, which in
--! 5.4.9 is LUAI_MAXCCALLS (200) without changing anything (lstate.c). This
--! tree had the C function but no debug.setcstacklimit. Printed: the results
--! and the argument errors.
print(type(debug.setcstacklimit))
print(debug.setcstacklimit(300), debug.setcstacklimit(0), debug.setcstacklimit("10"))
print(debug.setcstacklimit(2^40), debug.setcstacklimit(-1), debug.setcstacklimit(5.0))
print(pcall(debug.setcstacklimit, 1.5))
print(pcall(debug.setcstacklimit))
print(pcall(debug.setcstacklimit, {}))
print(pcall(debug.setcstacklimit, "x"))
local r
for i = 1, 100 do r = debug.setcstacklimit(i) end
print("hot", r)
