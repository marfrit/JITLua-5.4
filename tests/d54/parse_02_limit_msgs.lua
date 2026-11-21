--! modes: A
--! timeout: 60
-- Parser limit messages: PUC words them "too many X (limit is N) in <where>"
-- (lparser.c errorlimit). Where the limit is the same limit, the wording must
-- match; only the nesting depth itself is a difference (PUC counts syntactic
-- nesting with its C-call limit and says "C stack overflow", this tree has a
-- fixed level counter).

local function m (s)
  local f, msg = load(s)
  if f then return "LOADED" end
  return tostring(msg):gsub('^%[string "[^"]*"%]:%d+: ', ''):gsub('^%d+: ', '')
end

local function rep (n, s) return string.rep(s, n) end

-- The ten shapes of the PUC suite (errors.lua "testing syntax limits"), the
-- 100-level version must load and the 500-level version must fail.
local cases = {
  {"local a; a", ",a", "= 1", ",1"},
  {"local a; a=", "{", "0", "}"},
  {"return ", "(", "2", ")", ""},
  {"local function a (x) return x end; return ", "a(", "2.2", ")", ""},
  {"", "do ", "", " end"},
  {"", "while a do ", "", " end"},
  {"local a; ", "if a then else ", "", " end"},
  {"", "function foo () ", "", " end"},
  {"local a = ''; return ", "a..", "'a'", "", ""},
  {"local a = 1; return ", "a^", "a", "", ""},
}
for i, c in ipairs(cases) do
  local ok100 = load(c[1] .. rep(100, c[2]) .. c[3] .. rep(100, c[4]))
  print("case", i, "100 loads:", ok100 ~= nil)
  print("case", i, "500 says:", m(c[1] .. rep(500, c[2])))
end

-- The same limits PUC names: local variables, upvalues, constants, labels.
local names = {}
for i = 1, 210 do names[i] = "v" .. i end
print("many locals:", m("local " .. table.concat(names, ", ")))
local ups = {}
for i = 1, 210 do ups[i] = "u" .. i end
print("many upvalues:", m("do local " .. table.concat(ups, ", ") ..
  [[ return function () end end]]))
print("many constants:", m("return " .. table.concat((function()
  local t = {} for i = 1, 70000 do t[i] = i end return t end)(), "+")))
local labs = {}
for i = 1, 210 do labs[i] = "::l" .. i .. "::" end
print("many labels:", m(table.concat(labs, ";")))
