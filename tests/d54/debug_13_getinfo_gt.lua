--! §4.6 debug.getinfo rejects an option string that starts with '>' with
--! "invalid option '>'" before it looks at the function or level (PUC
--! ldblib.c db_getinfo, luaL_argcheck); a '>' anywhere else is an invalid
--! option of lua_getinfo. This tree passed a leading '>' on to lj_debug_getinfo,
--! which then took (and popped) a function from the stack of the inspected
--! thread. Printed: the errors, and the state of a coroutine inspected that way.
local function p(label, ...)
  local ok, r = pcall(debug.getinfo, ...)
  print(label, ok, ok and type(r) or r)
end
p("level >", 1, ">S")
p("func >", print, ">S")
p("func >>", print, ">>")
p("level S>", 1, "S>")
p("func S>", print, "S>")
p("only >", 1, ">")
local co = coroutine.create(function(...) coroutine.yield(print, ...) return "done" end)
print(coroutine.resume(co, 1, 2))
p("co level >", co, 1, ">S")
p("co func >", co, print, ">f")
p("co level >f", co, 0, ">f")
p("co ok", co, 1, "S")
print(coroutine.status(co), coroutine.resume(co))
local n = 0
for _ = 1, 100 do if not pcall(debug.getinfo, 1, ">l") then n = n + 1 end end
print("hot", n)
