--! §4.1 metamethod matrix for + - * / % ^ across operand types (5.1-parseable)
-- Operand kinds: integer, float, numeric string, table with mm, table without.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local trace = {}
local function mk(tag, ops)
  local mt = {}
  for _, op in ipairs(ops) do
    mt["__" .. op] = function(a, b)
      trace[#trace + 1] = tag .. ":" .. op
      return 42
    end
  end
  return setmetatable({}, mt)
end
local OPS = { "add", "sub", "mul", "div", "mod", "pow" }
local SYM = { add = "+", sub = "-", mul = "*", div = "/", mod = "%", pow = "^" }
local kinds = {
  int = 3, float = 3.0, str = "3",
  mm = mk("T", OPS), plain = setmetatable({}, {}),
}
local order = { "int", "float", "str", "mm", "plain" }
for _, op in ipairs(OPS) do
  for _, ka in ipairs(order) do
    for _, kb in ipairs(order) do
      local a, b = kinds[ka], kinds[kb]
      trace = {}
      local f = load("return function(a,b) return a " .. SYM[op] .. " b end")()
      local ok, res = pcall(f, a, b)
      local err = ok and "" or tostring(res):gsub("^.-:%d+: ", "")
      p(op, ka, kb, ok, ok and res or err, table.concat(trace, ","))
    end
  end
end
-- left-operand metamethod wins; string coercion only when no metamethod applies
p("left wins", (mk("L", OPS) + mk("R", OPS)))
p("unary minus mm", -setmetatable({}, { __unm = function() return "unm" end }))
p("unm float", -3.0, math.type(-3.0))
