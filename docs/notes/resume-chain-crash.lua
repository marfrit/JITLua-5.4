-- Repro for the resume-chain SIGSEGV (see resume-chain-crash.md).
-- Run: luajit -joff docs/notes/resume-chain-crash.lua   (and -jon)
-- PUC 5.4.9: d=196/197 "bottom", d>=198 "err@N:C stack overflow", rc=0.
-- JITLua integ7 on x86_64: d=196..200 "bottom", then SIGSEGV (rc=139).
-- JITLua integ7 on aarch64: d=196..200 "bottom", d>=201 clean
--   "err@N:C stack overflow" (no crash, but 3 levels deeper than PUC).
local function level(i)
  if i == 0 then return "bottom" end
  local co = coroutine.create(function() return level(i - 1) end)
  local ok, r = coroutine.resume(co)
  if not ok then return "err@"..i..":"..tostring(r) end
  return r
end
for _, d in ipairs{196, 197, 198, 199, 200, 201, 202, 250} do
  io.write("d="..d.." ")
  io.write(tostring(level(d)).."\n")
  io.flush()
end
