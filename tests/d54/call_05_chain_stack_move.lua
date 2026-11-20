--! Resolving a __call chain can grow the Lua stack, and growing it can move
--! it. Everything the interpreter keeps in registers across that call setup
--! has to survive the move. A fast function at the end of the chain returns
--! straight into the calling Lua function without reloading that function's
--! state, so the caller's constants are the first thing to go wrong: the
--! strings and numbers below are loaded right after such a call.
local unpack = table.unpack
local function mkchain(n, f)
  local u = f
  for i = 1, n do u = setmetatable({}, {__call = u}) end
  return u
end

local callees = {
  {"rawget", rawget}, {"getmetatable", getmetatable}, {"assert", assert},
  {"ipairs", ipairs}, {"pairs", pairs}, {"rawequal", rawequal},
  {"type", type}, {"lua", function(...) return select("#", ...) end},
}
for _, c in ipairs(callees) do
  for _, n in ipairs{1, 2, 30, 300, 3000} do
    local u = mkchain(n, c[2])
    -- A new coroutine has a small stack: the first call has to grow it.
    local co = coroutine.wrap(function(a)
      local x = u("abc", 1)
      local s = "k1" .. a
      local y = u("abc", 2)
      return s, 2.5, #("xyz" .. a), type(x) == type(y)
    end)
    print(c[1], n, co("q"))
    -- The same in tail position, and directly under pcall.
    local t = coroutine.wrap(function(a)
      local function tail() return u("abc", 1) end
      local x = tail()
      return "t1" .. a, 3.5, type(x)
    end)
    print(c[1], n, "tail", t("q"))
    local pc = coroutine.wrap(function(a)
      local ok = pcall(u, "abc", 1)
      return "p1" .. a, 4.5, ok
    end)
    print(c[1], n, "pcall", pc("q"))
  end
end

-- One level of __call at every stack alignment: somewhere on the way down
-- the call setup is the one that has to grow the stack.
local obj = setmetatable({}, {__call = rawequal})
local function rec(d, a, b)
  if d == 0 then return 0 end
  local r = obj(d, a)
  local k = "const"
  assert(r == false and k == "const")
  return 1 + rec(d - 1, a, b)
end
for pad = 0, 9 do
  local co = coroutine.wrap(function(...) return rec(3000, 1, 2) end)
  assert(co(table.unpack({1, 2, 3, 4, 5, 6, 7, 8, 9}, 1, pad)) == 3000)
end
print("align ok")
