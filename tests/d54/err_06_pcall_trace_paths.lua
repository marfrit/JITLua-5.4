--! §2.3/§4.3: the C-call counter of a compiled pcall/xpcall stays exact on
--! the paths where a guard sits next to the protected call: a callee that
--! changes between iterations (function, callable object), an argument whose
--! type changes inside the callee, an error raised by compiled code inside
--! the protected call, nested protected calls with errors at both levels,
--! pcall used as a __concat metamethod, recursion through pcall, a yield
--! across a compiled pcall and a finalizer that runs pcall. Each case prints
--! the change in usable pcall nesting depth, which must be 0.
local function depth()
  local n = 0
  local function rec() n = n + 1; pcall(rec) end
  pcall(rec)
  return n
end
local d0 = depth()
local function run(label, body)
  local ok, r = pcall(body)
  print(label, ok, r, depth() - d0)
end

local function f1(x) return x end
local function f2(x) return x + 1 end
local h = function(e) return e end
local fs = {f1, f1, f1, f1, f1, f1, f1, f2}

run("poly-pcall", function()
  local s = 0
  for i = 1, 4000 do local ok, v = pcall(fs[(i & 7) + 1], i); s = s + v end
  return s
end)

run("poly-xpcall", function()
  local s = 0
  for i = 1, 4000 do local ok, v = xpcall(fs[(i & 7) + 1], h, i); s = s + v end
  return s
end)

local c1 = setmetatable({}, {__call = function(_, x) return x end})
local c2 = setmetatable({}, {__call = function(_, x) return x + 1 end})
local cs = {c1, c1, c1, c1, c1, c1, c1, c2}
run("poly-callable", function()
  local s = 0
  for i = 1, 4000 do local ok, v = pcall(cs[(i & 7) + 1], i); s = s + v end
  return s
end)

local hs = {h, h, h, h, h, h, h, function(e) return e end}
run("poly-handler", function()
  local s = 0
  for i = 1, 4000 do local ok, v = xpcall(f1, hs[(i & 7) + 1], i); s = s + v end
  return s
end)

local xs = {}
for i = 1, 4000 do xs[i] = (i % 8 == 0) and 1.5 or i end
run("arg-type", function()
  local s = 0
  for i = 1, 4000 do local ok, v = pcall(f2, xs[i]); s = s + v end
  return s
end)

local ns = {}
for i = 1, 4000 do ns[i] = (i % 500 == 0) and (1 << 40) or 2 end
run("error-in-compiled-callee", function()
  local bad, rep = 0, string.rep
  for i = 1, 4000 do
    local ok, v = pcall(rep, "abc", ns[i])
    if not ok then bad = bad + 1 end
  end
  return bad
end)

run("nested", function()
  local n = 0
  for i = 1, 4000 do
    local ok = pcall(function()
      local ok2 = pcall(function() if i % 7 == 0 then error("x") end end)
      if i % 11 == 0 then error("y") end
    end)
    if not ok then n = n + 1 end
  end
  return n
end)

-- pcall as a metamethod: `q .. a .. b` runs pcall(a, b) first and then
-- concatenates q with its first result; q alternates between two metatables.
do
  local a = setmetatable({}, {__concat = pcall, __call = function(_, b) return b end})
  local qs = {}
  for i = 1, 8 do
    qs[i] = setmetatable({}, {__concat = function(_, r) return r and 1 or 0 end})
  end
  run("concat-metamethod", function()
    local s = 0
    for i = 1, 4000 do s = s + (qs[(i & 7) + 1] .. a .. i) end
    return s
  end)
end

run("recursion", function()
  local function fib(n)
    if n < 2 then return n end
    local _, a = pcall(fib, n - 1)
    local _, b = pcall(fib, n - 2)
    return a + b
  end
  return fib(22)
end)

run("yield-across", function()
  local co = coroutine.wrap(function()
    for i = 1, 4000 do
      pcall(function() if i % 16 == 0 then coroutine.yield(i) end end)
    end
    return "done"
  end)
  local n = 0
  while co() ~= "done" do n = n + 1 end
  return n
end)

run("finalizer", function()
  local hits = 0
  local mt = {__gc = function() pcall(error, "x"); hits = hits + 1 end}
  for i = 1, 20000 do
    pcall(function() setmetatable({}, mt) end)
  end
  collectgarbage()
  return hits > 0
end)

print("alive", pcall(pcall, pcall, tostring, "x"))
