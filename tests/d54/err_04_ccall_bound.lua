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
