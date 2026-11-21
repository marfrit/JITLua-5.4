--! §5 collectgarbage parameters: setpause/setstepmul return the previous
--! value. incremental applies (pause, stepmul, stepsize) with PUC's /4 byte
--! storage (1234 -> 208, 5678 -> 556). generational takes (minormul,
--! majormul) and leaves the incremental knobs unchanged. The initial defaults
--! are tuning (JITLua 300/200, PUC 200/100, IMPL-DEFINED): each interpreter
--! asserts its own documented pair, so a changed default fails the test while
--! every later call is compared with PUC. Differential against PUC 5.4.9.
local function s(label, a, b)
  print(label .. " | " .. tostring(a) .. " / " .. tostring(b))
end
local function norm(e)
  local t = tostring(e)
  return t:gsub("^.-:%d+: ", "")
end
local function q(label, f, ...)
  local ok, a = pcall(f, ...)
  print(label .. " | ok=" .. tostring(ok) .. " | " ..
	(ok and tostring(a) or norm(a)))
end

-- First call returns the initial value. JITLua's documented default is the
-- measured speed policy 300/200 (IMPL-DEFINED); PUC's is 200/100.
local isjit = type(jit) == "table"
local wantp, wantm = isjit and 300 or 200, isjit and 200 or 100
local p0 = collectgarbage("setpause", 300)
local m0 = collectgarbage("setstepmul", 200)
-- The harness's GC-stress stage starts every arm with setpause 0; the
-- defaults are only asserted when nothing changed them before the chunk.
if p0 ~= 0 then
  assert(p0 == wantp, "setpause default " .. tostring(p0) .. " != " .. wantp)
  assert(m0 == wantm, "setstepmul default " .. tostring(m0) .. " != " .. wantm)
end
print("defaults documented | true")
s("after defaults",
  collectgarbage("setpause", 300), collectgarbage("setstepmul", 200))

local prev = collectgarbage("incremental", 1234, 5678, 0)
s("incremental prev", prev, collectgarbage("setpause", 0))
s("incremental stepmul", 0, collectgarbage("setstepmul", 0))

s("incremental roundtrip",
  collectgarbage("incremental", 200, 200, 200),
  collectgarbage("setpause", 200))
s("incremental roundtrip mul",
  0, collectgarbage("setstepmul", 200))

local gprev = collectgarbage("generational", 1, 2)
s("generational prev", gprev, collectgarbage("setpause", 200))
s("generational keeps stepmul", 0, collectgarbage("setstepmul", 200))

q("incremental pause 1.5", collectgarbage, "incremental", 1.5, 0, 0)
q("incremental stepmul 1.5", collectgarbage, "incremental", 0, 1.5, 0)
q("generational minormul 1.5", collectgarbage, "generational", 1.5, 2)
