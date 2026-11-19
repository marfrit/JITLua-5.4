--! EXTENSION: table.create is a LuaJIT extension; PUC 5.4 has no such
--! function (PUC src/ltablib.c tab_funcs lists only concat/insert/pack/
--! unpack/remove/move/sort). The tbl_01_lib.lua line for it is unreachable
--! (that file aborts earlier at the select check), so this file covers it.
print("type", type(table.create))
local ok, t = pcall(table.create, 4, 4)
print("call", ok, type(t))
if ok then
  t[1] = "a"
  t[5] = "b"
  print("len", #t, t[1], t[5])
end
