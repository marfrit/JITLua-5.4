--! timeout: 60
--! Jumps that are each short in the source must load however many follow
--! one another. This parser let a jump to the next instruction join the
--! list of a JMP emitted right there and take that JMP's final target, so
--! 33000 gotos, each to a label just before the next goto, were all patched
--! to the last label and failed with "control structure too long" (the
--! 16-bit jump operand); PUC loads them. The same for breaks out of loops
--! whose end is the next loop's jump, and for if-chains. Printed: the load
--! result and the value each chunk returns.
local function rep (s, n) return string.rep(s, n, " ") end
local function run (name, src)
  local f, e = load(src, "=x")
  if f then print(name, "ok", f()) else print(name, e) end
end
run("gotos to adjacent labels",
    "local v = 7\n" .. rep("do goto l; ::l:: end", 33000) .. "\nreturn v")
run("gotos, closure", "local v = 7\n" .. rep("do goto l; ::l:: end", 33000) ..
    "\nreturn (function () return v + 1 end)()")
run("gotos after a closure", "local v = 7 local f = function () return v end\n" ..
    rep("do goto l; ::l:: end", 33000) .. "\nreturn f()")
run("ifs", "local n = 0\n" .. rep("if n < 0 then n = 1 end", 20000) .. "\nreturn n")
run("breaks", "local n = 0\n" .. rep("while true do n = n + 1 break end", 20000) .. "\nreturn n")
run("nested and/or", "local a, b = 1, 2 local x\n" ..
    rep("x = (a and b) or (b and a)", 20000) .. "\nreturn x")
