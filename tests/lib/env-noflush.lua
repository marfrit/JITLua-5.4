-- The env setters (setfenv, debug.setupvalue on _ENV, debug.upvaluejoin on
-- _ENV) must not discard the compiled traces of unrelated code: the sandbox
-- idiom `f = load(src); debug.setupvalue(f, 1, env)` would otherwise flush
-- the whole trace cache on every call. Traces check the env at run time.
-- Run with -jon; with -joff there are no traces and the check is skipped.
local ok, jutil = pcall(require, "jit.util")
if not (jit and jit.status() and ok and jutil.traceinfo) then
  print("env-noflush: skipped (JIT off)"); return
end
local function hot() local s = 0; for i = 1, 1000 do s = s + i end; return s end
local fails = 0
local function check(name, setter)
  jit.flush()
  hot(); hot()
  if not jutil.traceinfo(1) then
    fails = fails + 1; print("FAIL " .. name .. ": no trace compiled"); return
  end
  setter()
  if not jutil.traceinfo(1) then
    fails = fails + 1; print("FAIL " .. name .. ": env setter flushed all traces")
  end
  assert(hot() == 500500)
end
local function target() return x end
check("setfenv", function() setfenv(target, {x = 1}) end)
check("debug.setupvalue", function()
  local ch = load("return x")
  assert(debug.setupvalue(ch, 1, {x = 2}) == "_ENV")
  assert(ch() == 2)
end)
check("debug.upvaluejoin", function()
  local a, b = load("return x"), load("return x")
  debug.setupvalue(b, 1, {x = 3})
  debug.upvaluejoin(a, 1, b, 1)
  assert(a() == 3)
end)
if fails > 0 then os.exit(1) end
print("env-noflush: ok")
