--! §4.1 math.random 5.4: xoshiro256** sequence must match PUC exactly for the
--! same seed, and randomseed must return the two seeds it used.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function seq(label, n, ...)
  local a = {}
  for i = 1, n do a[i] = tostring(math.random(...)) end
  p(label, table.concat(a, ","))
end
p("seed return", math.randomseed(42, 0))
seq("floats", 6)
seq("ints 1..10", 6, 1, 10)
seq("single arg", 6, 100)
math.randomseed(7, 123)
p("seed return 2", math.randomseed(7, 123))
seq("floats seed2", 4)
math.randomseed(0, 0)
seq("zero seed", 4)
math.randomseed(-1, -1)
seq("neg seed", 4)
-- Types: 5.4 returns integer for ranged calls, float for no-arg calls.
math.randomseed(1, 0)
p("types", math.type(math.random()), math.type(math.random(10)),
  math.type(math.random(1, 10)))
-- Same seed reproduces the same sequence.
math.randomseed(99, 0)
local a1, a2, a3 = math.random(), math.random(), math.random()
math.randomseed(99, 0)
p("reproducible", a1 == math.random(), a2 == math.random(), a3 == math.random())
p("errors", pcall(math.random, 2, 1), pcall(math.random, 1, 2, 3))
p("random 0 type", (function()
  math.randomseed(5, 0)
  local v = math.random(0)
  return math.type(v), v >= 0
end)())
