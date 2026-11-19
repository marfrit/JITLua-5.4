--! §2.3/§4.3: a deep chain of nested coroutine.resume calls must never crash
--! the VM. PUC 5.4.9 stops the chain at its C-call bound with a clean
--! "C stack overflow" caught by the caller; this fork must do the same.
--! Every depth returns (bottom or caught), and the depths well above the
--! bound must end in a caught error, never a crash: a VM that crashes prints
--! no further line, which is how the harness sees it. The exact depth at
--! which the bound fires is covered by err_06 (deltas against PUC); the
--! absolute depth differs because the C-call baseline differs.
local function level(i)
  if i == 0 then return "bottom" end
  local co = coroutine.create(function() return level(i - 1) end)
  local ok, r = coroutine.resume(co)
  if not ok then return "caught" end
  return r
end
local depths = {}
for d = 1, 10 do depths[#depths + 1] = d end
for _, d in ipairs{50, 100, 150, 175, 190, 196, 197, 198, 199, 200,
                   201, 202, 250, 300} do depths[#depths + 1] = d end
-- Deeper probe: the bound must fire long before this and the chain must end
-- in a clean caught error, never a crash.
for _, d in ipairs{1000} do depths[#depths + 1] = d end
for _, d in ipairs(depths) do
  local r = level(d)
  assert(r == "bottom" or r == "caught", "unexpected result at depth "..d)
  -- PUC 5.4.9 and this fork both reach the bound below 250.
  if d >= 250 then
    assert(r == "caught", "depth "..d.." ran past the C-call bound")
  end
  io.write("d="..d.." clean\n")
  io.flush()
end
io.write("all "..#depths.." depths clean\n")

-- The same depth through coroutine.wrap: the bound error is thrown in the
-- resumer, so the whole chain must end in a caught error, never a crash.
local function wlevel(i)
  if i == 0 then return "bottom" end
  local w = coroutine.wrap(function() return wlevel(i - 1) end)
  return w()
end
for _, d in ipairs{250, 1000} do
  local ok = pcall(wlevel, d)
  assert(not ok, "wrap chain at depth "..d.." ran past the C-call bound")
  io.write("wrap="..d.." caught\n")
  io.flush()
end
