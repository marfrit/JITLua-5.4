--! §2.3/§4.3: the pcall/xpcall C-call nesting bound (PUC ldo.c
--! luaE_checkcstack / LUAI_MAXCCALLS). A deep pcall recursion raises
--! "C stack overflow", and a message handler that errors while handling
--! C-stack overflow ends in "error in error handling".
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

-- a deep pcall recursion hits the C-call bound
p("cstkov", (function()
  local function rec(n)
    if n <= 0 then return end
    local ok, err = pcall(rec, n - 1)
    if not ok then error(err, 0) end
  end
  return pcall(rec, 100000)
end)())

-- C-stack overflow while handling C-stack overflow
p("handler", (function()
  local function loop() assert(pcall(loop)) end
  return xpcall(loop, loop)
end)())

-- ccallnest must be exact on every path: a recursive-pcall depth probe is
-- unchanged after calls that used to leak or underflow it. The absolute depth
-- differs from PUC (PUC's C-call baseline is nonzero), so print the delta.
local function depth()
  local n = 0
  local function rec() n = n + 1; pcall(rec) end
  pcall(rec)
  return n
end
local d0 = depth()
local function probe(name) p(name, depth() - d0) end
for i = 1, 300 do pcall(xpcall, print, nil) end  -- xpcall(f, nonfunction)
probe("after-bad1")
for i = 1, 300 do pcall(pcall) end               -- pcall()
probe("after-bad2")
for i = 1, 300 do pcall(xpcall, print) end       -- xpcall(f)
probe("after-bad3")
for i = 1, 300 do pcall(xpcall) end              -- xpcall()
probe("after-bad4")
local function loop() assert(pcall(loop)) end
p("handler2", xpcall(loop, loop))
probe("after-handler")
p("fine", pcall(function() return "fine" end))
