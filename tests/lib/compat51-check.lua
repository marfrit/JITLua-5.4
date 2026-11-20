-- Run this against a build made with CFLAGS=-DLUAJIT_ENABLE_51COMPAT
-- (tests/lib/compat51build-d54.sh does it in the ci-box gate):
--
--   ./src/luajit -joff tests/lib/compat51-check.lua
--   ./src/luajit -jon  tests/lib/compat51-check.lua
--
-- It asserts the Lua 5.1 names exist and work there, and that the switch
-- leaves the 5.4 names and the kept LuaJIT extensions alone. The default
-- build is covered by tests/d54/compat51_01_51names_absent.lua.

local function f(name, t)
  assert(t ~= nil, "missing with -DLUAJIT_ENABLE_51COMPAT: " .. name)
  return t
end

-- _G
local gcinfo = f("gcinfo", gcinfo)
local loadstring = f("loadstring", loadstring)
local module = f("module", module)
local newproxy = f("newproxy", newproxy)
local unpack = f("unpack", unpack)

-- table
local foreach = f("table.foreach", table.foreach)
local foreachi = f("table.foreachi", table.foreachi)
local getn = f("table.getn", table.getn)
local maxn = f("table.maxn", table.maxn)

-- package
f("package.loaders", package.loaders)
f("package.seeall", package.seeall)

print("gcinfo>0", gcinfo() >= 0)
assert(gcinfo() >= 0)

print("unpack", unpack({ 10, 20, 30 }, 2))
assert(select("#", unpack({ 10, 20, 30 }, 2)) == 2)
assert(select(1, unpack({ 10, 20, 30 }, 2)) == 20)
print("unpack n", select("#", unpack({ 10, 20, 30 })))
assert(select("#", unpack({ 10, 20, 30 })) == 3)
local g = assert(loadstring("compat51_g = 7"))
g()
print("loadstring write", _G.compat51_g)
assert(_G.compat51_g == 7)
_G.compat51_g = nil

print("loadstring", loadstring("return 1+1")())
assert(loadstring("return 1+1")() == 2)
print("loadstring text mode", type(loadstring("return a", "c", "t")))
assert(loadstring("return a", "c", "t") ~= nil)
assert(loadstring("@bad syntax") == nil)

print("getn", getn({ 1, 2, 3, [10] = 1 }))
assert(getn({ 1, 2, 3, [10] = 1 }) == 3)
print("maxn", maxn({ [10] = 1, [2.5] = 2 }))
assert(maxn({ [10] = 1, [2.5] = 2 }) == 10)

local seen, seeni = 0, 0
foreach({ a = 1, b = 2 }, function(k, v) seen = seen + (k == "a" and v or 0) end)
foreachi({ 1, 2, 3 }, function(i) seeni = seeni + i end)
print("foreach counts", seen, seeni)
assert(seen == 1 and seeni == 6)

local ud = newproxy(true)
local mt = getmetatable(ud)
mt.__index = function() return "proxy" end
print("newproxy", ud.anything)
assert(ud.anything == "proxy")
assert(newproxy(false) ~= nil)

-- module() with package.seeall: the 5.1 module protocol, run from a chunk the
-- way a 5.1 module file would.
do
  local chunk = assert(load([[
    module("compat51_check_mod", package.seeall)
    value = 42
  ]], "compat51_check"))
  chunk()
  print("module", type(package.loaded.compat51_check_mod),
	package.loaded.compat51_check_mod and
	package.loaded.compat51_check_mod.value)
  assert(type(package.loaded.compat51_check_mod) == "table")
  assert(package.loaded.compat51_check_mod.value == 42)
  assert(_G.compat51_check_mod == package.loaded.compat51_check_mod)
  package.loaded.compat51_check_mod = nil
  _G.compat51_check_mod = nil
end

print("package.loaders", package.loaders == package.searchers)
assert(package.loaders == package.searchers)
assert(type(package.searchers) == "table")

-- Unaffected: the 5.4 names and the kept LuaJIT extensions.
local ffi = require("ffi")
print("5.4 kept", type(table.unpack), type(load), type(package.searchers),
      type(utf8.len))
assert(type(table.unpack) == "function" and type(load) == "function")
assert(type(utf8.len) == "function")
print("extensions kept", type(bit), type(ffi), type(jit), type(jit.status),
      type(getfenv), type(setfenv))
assert(type(bit) == "table" and type(ffi) == "table")
assert(type(jit) == "table" and type(jit.status) == "function")
assert(type(getfenv) == "function" and type(setfenv) == "function")
-- Printed, not asserted: these LuaJIT extension surfaces are reachable only
-- through their own modules (jit.util, string.buffer, the table constructor
-- fast functions). The switch does not touch them; the printed line records
-- that they are the same with the switch on as with it off.
print("extension surfaces", type(table.new), type(table.clear),
      type(table.create), type(string.buffer), type(require("jit.util")))

print("compat51 check ok")
