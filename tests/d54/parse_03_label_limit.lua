--! timeout: 120
--! 5.4 parser: the visible labels and the pending gotos of a chunk are each
--! limited to 32767 (PUC lparser.c newlabelentry grows the two lists up to
--! SHRT_MAX). Past that, load fails with "too many labels/gotos (limit is
--! 32767)" and no source position. Labels count while they are visible,
--! forward gotos and breaks until their label is reached; backward gotos
--! and labels of closed blocks do not count, and the end of a loop briefly
--! adds PUC's "break" label. Many breaks or backward gotos in one body hit
--! the jump distance limit first here, a separate implementation limit, so
--! those shapes stay short. Printed: the first line of the load result for
--! each shape at and just above the limit. Fixed output only.
local function try (name, src)
  local f, err = load(src, "=x")
  print(name, f and "ok" or tostring(err):match("^[^\n]*"))
end
local function rep (pre, post, n)  -- pre .. i .. post, n times
  local t = {}
  for i = 1, n do t[i] = pre .. i .. post end
  return table.concat(t, " ")
end
for _, n in ipairs{32767, 32768} do  -- just at and just above the limit
  try("visible labels " .. n, "local x " .. rep("::l", ":: x=1", n))
  try("forward gotos " .. n, string.rep("goto l ", n) .. "::l::")
end
try("labels in closed blocks 32768", "local x " .. rep("do ::l", ":: x=1 end", 32768))
-- Labels of an enclosing function stay visible while a nested one is parsed.
try("labels across functions",
    "local x " .. rep("::l", ":: x=1", 32760) ..
    " local function f () " .. rep("::m", ":: x=2", 8) .. " end")
-- Gotos resolved on the way do not count any more.
try("resolved gotos", string.rep("do goto l ::l:: end ", 30000))
-- Backward gotos are not pending (kept short: the jump distance has its
-- own, smaller limit here).
try("backward gotos", "::l:: " .. string.rep("goto l ", 5000))
-- The loop's own "break" label at the end of a loop body.
try("loop end at the limit", "local x " .. rep("::l", ":: x=1", 32767) ..
    " while x do x = nil end")
-- The limits still leave normal programs alone.
try("small", "for i = 1, 3 do if i == 2 then goto c end ::c:: end")
