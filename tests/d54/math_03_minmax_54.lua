--! §4.2 math.min/math.max are PUC's lua_compare loops: the winning argument
--! is returned unchanged (subtype kept), a numeric string next to a number
--! raises "attempt to compare ...", two strings compare lexicographically,
--! the first argument wins ties including NaN, and signed zeros keep the
--! first argument. Differential against PUC 5.4.9.
local function d(v)
  if type(v) == "number" then return tostring(v) .. " (" .. math.type(v) .. ")"
  else return type(v) .. ":" .. tostring(v) end
end
local function p(label, ...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = d((select(i, ...))) end
  print(label .. " | " .. table.concat(t, " / "))
end
local function norm(e)
  local s = tostring(e)
  s = s:gsub("^.-:%d+: ", "")
  return s
end
local function q(label, f, ...)
  local ok, a = pcall(f, ...)
  print(label .. " | ok=" .. tostring(ok) .. " | " ..
	(ok and d(a) or norm(a)))
end

p("min mixed", math.min(1, 1.5))
p("max mixed", math.max(1, 1.0))
p("max mixed3", math.max(1, 2, 1.5))
p("min mixed3", math.min(1.5, 2, 1))
p("max int", math.max(1, 2))
p("min int", math.min(1, 2))
p("max float", math.max(1.0, 2.0))
p("min float", math.min(1.0, 2.0))
p("max equal", math.max(2.0, 2))
p("min equal", math.min(2, 2.0))
p("min zeros", math.min(0.0, -0.0), math.max(0.0, -0.0))
p("min neg zeros", math.min(-0.0, 0.0), math.max(-0.0, 0.0))
p("max nan first", math.max(0 / 0, 1), math.min(0 / 0, 1))
p("max nan last", math.max(1, 0 / 0), math.min(1, 0 / 0))
p("max nan float", math.max(0 / 0, 1.0), math.min(1.0, 0 / 0))
q("min str num", math.min, "1", 2)
q("max str num", math.max, 2, "1")
q("min two strings", math.min, "b", "a")
q("max two strings", math.max, "b", "a")
q("min no value", math.min)
q("max boolean", math.max, true, false)
q("min nil", math.min, 1, nil)
