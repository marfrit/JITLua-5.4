--! §4.1 __band __bor __bxor __shl __shr __bnot dispatch (5.4 operand matrix)
-- 5.4-only syntax.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local log = {}
local function mm(name)
  return function(a, b)
    log[#log + 1] = name
    return 7
  end
end
local function obj(name, extra)
  local mt = { __band = mm(name .. ".band"), __bor = mm(name .. ".bor"),
               __bxor = mm(name .. ".bxor"), __shl = mm(name .. ".shl"),
               __shr = mm(name .. ".shr"), __bnot = mm(name .. ".bnot") }
  for k, v in pairs(extra or {}) do mt[k] = v end
  return setmetatable({}, mt)
end
local A, B = obj("A"), obj("B")
p("obj&obj", A & B, table.concat(log, ",")); log = {}
p("obj&int", A & 3, table.concat(log, ",")); log = {}
p("int&obj", 3 & A, table.concat(log, ",")); log = {}
p("obj&float", A & 3.0, table.concat(log, ",")); log = {}
p("float&obj", 3.5 & A, table.concat(log, ",")); log = {}
p("obj|obj", A | B, table.concat(log, ",")); log = {}
p("obj~obj", A ~ B, table.concat(log, ",")); log = {}
p("obj<<obj", A << B, table.concat(log, ",")); log = {}
p("obj>>int", A >> 2, table.concat(log, ",")); log = {}
p("~obj", ~A, table.concat(log, ",")); log = {}
p("no mm", pcall(function() return setmetatable({}, {}) & 1 end))
p("partial mm", (setmetatable({}, { __band = mm("only") }) & 1), table.concat(log, ",")); log = {}
p("string mm", pcall(function() return "3" & setmetatable({}, { __band = mm("s") }) end))
assert(A & B == 7, "metamethod result is used verbatim")
