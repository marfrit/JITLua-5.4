--! §5 LuaJIT extensions must be additive: getfenv/setfenv (Lua functions) and
--! the package.preload modules (ffi, jit.profile, jit.util, string.buffer,
--! table.clear, table.new), plus the jit/bit tables and loadstring, are visible to a 5.4 program only if it iterates
--! globals or package.preload; every such extra is in the documented set, so
--! a program that reads named globals or named modules sees PUC behavior.
--! Differential against PUC 5.4.9 (PUC has no extras; the counters are 0).
local extra_globals = {
  getfenv = true, setfenv = true, jit = true, bit = true,
  loadstring = true,
}
local extra_preload = {
  ["ffi"] = true, ["jit.profile"] = true, ["jit.util"] = true,
  ["string.buffer"] = true, ["table.clear"] = true, ["table.new"] = true,
}
local std = {
  _G = true, _VERSION = true, assert = true, collectgarbage = true,
  dofile = true, error = true, getmetatable = true, ipairs = true,
  load = true, loadfile = true, next = true, pairs = true, pcall = true,
  print = true, rawequal = true, rawget = true, rawlen = true, rawset = true,
  select = true, setmetatable = true, tonumber = true, tostring = true,
  type = true, warn = true, xpcall = true,
  coroutine = true, debug = true, io = true, math = true, os = true,
  package = true, require = true, arg = true,
  string = true, table = true, utf8 = true,
}
local unexpected = 0
for k in pairs(_G) do
  if type(k) == "string" and not std[k] and not extra_globals[k] then
    unexpected = unexpected + 1
    print("unexpected global | " .. k)
  end
end
local unexpected_preload = 0
for k in pairs(package.preload) do
  if type(k) == "string" and not extra_preload[k] then
    unexpected_preload = unexpected_preload + 1
    print("unexpected preload | " .. k)
  end
end
print("unexpected globals | " .. unexpected)
print("unexpected preload | " .. unexpected_preload)
-- Named lookups and normal 5.4 behavior are unaffected.
print("named globals | " .. type(assert) .. "," .. type(string.format))
print("named preload absent-ish | " .. tostring(package.preload["no.such.module"]))
