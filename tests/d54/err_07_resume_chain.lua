--! §2.3/§4.3: a deep chain of nested coroutine.resume calls must never crash
--! the VM. PUC 5.4.9 stops the chain at its C-call bound with a clean
--! "C stack overflow" caught by the caller; this fork currently runs the
--! chain to completion. Both are clean, so the test only records that every
--! depth returns, and it is deliberately silent about the depth at which the
--! bound fires (that differs; see docs/notes/resume-chain-crash.md). A VM
--! that crashes prints no further line, which is how the harness sees it.
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
for _, d in ipairs(depths) do
  local r = level(d)
  assert(r == "bottom" or r == "caught", "unexpected result at depth "..d)
  io.write("d="..d.." clean\n")
  io.flush()
end
io.write("all "..#depths.." depths clean\n")
