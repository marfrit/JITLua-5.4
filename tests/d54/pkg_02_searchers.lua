--! §5 package library 5.4 exactness, part 2: package.searchers, require's
--! loader protocol (two results, loader data, second return value), the
--! preload/Lua searchers, error accumulation and package.searchpath shapes.
--! Differential: JITLua-5.4 vs PUC-Lua 5.4.9 -- byte-identical output.
--!
--! Not covered: the LuaJIT-only sentinel that turns a recursive require into
--! "loop or previous error loading module" (PUC 5.4 recurses into a stack
--! overflow instead, so it cannot be compared here).
--!
--! Temporary directories come from os.tmpname(); every printed path has the
--! directory replaced by TEMP so both implementations print the same bytes.

local function repr(s)
  return '"' .. s:gsub('[\\"\n\t\r]', {
    ['\\'] = '\\\\', ['"'] = '\\"',
    ['\n'] = '\\n', ['\t'] = '\\t', ['\r'] = '\\r',
  }) .. '"'
end
local function nret(...) return select("#", ...) end

-- Replace the literal temp-directory prefix in a string.
local function nmk(dir)
  return function(s)
    local i = s:find(dir, 1, true)
    if not i then return s end
    return s:sub(1, i - 1) .. "TEMP" .. s:sub(i + #dir)
  end
end

print("== package table ==")
print("searchers|type=" .. type(package.searchers) ..
      "|loaders-compat=" ..
      tostring(package.loaders == nil or package.loaders == package.searchers) ..
      "|n=" .. #package.searchers)

print("== preload searcher ==")
package.preload.x = function(n, d)
  print("x-loader|" .. n .. "|preload-data=" .. tostring(d == ":preload:"))
  return { v = 1 }
end
local xm, xd = require("x")
print("preload-x|registered=" .. tostring(xm == package.loaded.x) ..
      "|v=" .. tostring(xm.v) .. "|data=" .. repr(xd))
print("preload-x-nret|" .. nret(require("x")))
local xm2, xd2 = require("x")
print("preload-x-cached|same=" .. tostring(xm2 == xm) ..
      "|data=" .. tostring(xd2))

package.preload.y = function(n, d) end
local ym, yd = require("y")
print("preload-y|true=" .. tostring(ym == true) .. "|data=" .. repr(yd))
print("preload-y-nret|" .. nret(require("y")))

package.preload.z = function(n, d) return nil end
local zm, zd = require("z")
print("preload-z-nil|true=" .. tostring(zm == true) .. "|data=" .. repr(zd))

print("== searcher protocol ==")
local saved = package.searchers
package.searchers = {
  function(n) return "alpha" end,
  function(n) return nil end,
  function(n) return 123 end,
  function(n) return "omega" end,
}
local ok, err = pcall(require, "ghost")
print("custom-err|ok=" .. tostring(ok) .. "|err=" .. repr(err))
package.searchers = saved

-- A searcher supplying loader + data: the loader gets (name, data) and
-- require returns (module, data).
local seen
package.searchers = {
  function(n)
    return function(nn, dd) seen = nn .. "|" .. dd; return { k = 1 } end, "the-data"
  end,
}
local cm, cd = require("custommod")
print("custom-loader|seen=" .. repr(seen) .. "|k=" .. tostring(cm.k) ..
      "|data=" .. repr(cd))
print("custommod-registered=" .. tostring(cm == package.loaded.custommod))

-- A loader returning nothing: module becomes true, loader data is kept.
package.searchers = {
  function(n) return function(nn, dd) end, "nil-data" end,
}
local nm, nd = require("nilmod")
print("nil-loader|true=" .. tostring(nm == true) .. "|data=" .. repr(nd))
package.searchers = saved

print("== default searchers error messages ==")
local ok2, err2 = pcall(require, "pkg_02_absent_module")
print("default-err|ok=" .. tostring(ok2) .. "|err=" .. repr(err2))

print("== searchers must be a table ==")
local saved2 = package.searchers
package.searchers = 42
local ok3, err3 = pcall(require, "squirrel")
print("searchers-not-table|ok=" .. tostring(ok3) .. "|err=" .. repr(err3))
package.searchers = saved2

print("== Lua file searcher and searchpath ==")
local dir = os.tmpname()
os.remove(dir)  -- os.tmpname may pre-create the file on some systems
os.execute("mkdir -p '" .. dir .. "'")
local norm = nmk(dir)
local modpath = dir .. "/m.lua"
local f = io.open(modpath, "w")
f:write("local n, d = ...\nreturn { name = n, data = d }\n")
f:close()
local oldpath = package.path
package.path = dir .. "/?.lua"

local flm, fld = require("m")
print("file-mod|name=" .. tostring(flm.name) ..
      "|data=" .. norm(repr(fld)) ..
      "|arg-data=" .. tostring(flm.data == fld) ..
      "|registered=" .. tostring(flm == package.loaded.m))
print("file-mod-nret|" .. nret(require("m")))
local flm2, fld2 = require("m")
print("file-mod-cached|same=" .. tostring(flm2 == flm) ..
      "|data=" .. tostring(fld2))

local spok = package.searchpath("m", dir .. "/?.lua")
print("searchpath-ok|nil=" .. tostring(spok == nil) .. "|" .. norm(repr(spok)))
local sp1, sp2 = package.searchpath("absent", dir .. "/?.lua")
print("searchpath-miss|nil=" .. tostring(sp1 == nil) .. "|" .. norm(repr(sp2)))
local sp3, sp4 = package.searchpath("a.b", dir .. "/?.lua")
print("searchpath-sub|nil=" .. tostring(sp3 == nil) .. "|" .. norm(repr(sp4)))
local sp5 = package.searchpath("m", dir .. "/?.lua", ".", "/")
print("searchpath-dirsep|ok=" .. tostring(sp5 ~= nil) .. "|" .. norm(repr(sp5)))

os.remove(modpath)
local flm3 = require("m")  -- cached: no file access needed
print("file-mod-after-remove|same=" .. tostring(flm3 == flm))
package.path = oldpath
os.execute("rm -rf '" .. dir .. "'")

print("done")
