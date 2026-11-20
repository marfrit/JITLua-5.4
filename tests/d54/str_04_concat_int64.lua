--! §6.4.1 table.concat: the start and end arguments are 5.4 integers
--! (luaL_optinteger), and the error names the index that failed as a
--! lua_Integer. LuaJIT clamped both bounds to int32, so the message for
--! math.maxinteger said 2147483647 and a table keyed outside int32 was not
--! found. PUC's suite checks the message in strings.lua:392.
local t = {[math.maxinteger] = "x", [math.mininteger] = "y"}
print(pcall(table.concat, {}, "", math.maxinteger, math.maxinteger))
print(pcall(table.concat, {}, " ", math.mininteger, math.mininteger))
print(pcall(table.concat, t, "", math.maxinteger, math.maxinteger))
print(pcall(table.concat, t, ",", math.mininteger, math.mininteger))
local u = {[1] = "a", [2147483648] = "b", [3] = "c"}
print(pcall(table.concat, u, "-", 1, 2147483648))
print(pcall(table.concat, u, "-", 2147483648, 2147483648))
print(pcall(table.concat, u, "-", 1, 3))
print(pcall(table.concat, {1.5, true}, "|"))
print(pcall(table.concat, {1, 1.5, 2}, "|", 1, 3))
print(pcall(table.concat, {1}, "|", 1.5, 2))
print("ok")
