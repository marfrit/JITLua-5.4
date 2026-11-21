--! §4.1/§5 the Lua 5.1 leftovers are behind -DLUAJIT_ENABLE_51COMPAT: the
--! default build must not define these names at all. PUC-Lua 5.4.9 has none
--! of them, so every line here and every assert holds on both arms; the
--! switch-on build is checked by tests/lib/compat51-check.lua, which a
--! dedicated ci-box stage runs against a build with the switch.
--!
--! Kept on purpose (deliberate LuaJIT extensions, not 5.1 leftovers, and not
--! all comparable with PUC): getfenv/setfenv, the table constructor
--! extensions, bit.*, ffi, jit.*, string.buffer. They are re-checked in the
--! switch-on build (tests/lib/compat51-check.lua).

local base = {
  "gcinfo", "module", "newproxy", "unpack",
}
local tab = { "foreach", "foreachi", "getn", "maxn" }
local pkg = { "loaders", "seeall" }

for _, n in ipairs(base) do
  print("base", n, tostring(rawget(_G, n)))
  assert(rawget(_G, n) == nil, "5.1 name still in _G: " .. n)
end
for _, n in ipairs(tab) do
  print("table", n, tostring(rawget(table, n)))
  assert(rawget(table, n) == nil, "5.1 name still in table: " .. n)
end
for _, n in ipairs(pkg) do
  print("package", n, tostring(rawget(package, n)))
  assert(rawget(package, n) == nil, "5.1 name still in package: " .. n)
end

-- The 5.4 replacements are there, and the metatable of the package library
-- is unaffected by the switch.
print("table.unpack", type(table.unpack), "load", type(load),
      "package.searchers", type(package.searchers))
assert(type(table.unpack) == "function")
assert(type(load) == "function")
assert(type(package.searchers) == "function")

-- Nothing else in the standard libraries was dropped with them.
for _, lib in ipairs({ "coroutine", "debug", "io", "math", "os", "string",
		       "table", "utf8" }) do
  assert(type(_G[lib]) == "table", lib)
end
