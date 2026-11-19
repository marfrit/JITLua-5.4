--! §2.3/§4.3: pcall/xpcall inside traces must keep the C-call counter exact
--! (penlight test-pretty shape: pcall in a for-in loop, error inside the
--! protected call, a side exit, coroutine.wrap, and the depth probe).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

p("forin", (function()
  local function iter(s, i) i = i + 1; if i <= 100000 then return i, i end end
  local n = 0
  for i, v in iter, nil, 0 do
    local ok, r = pcall(function() return v end)
    if ok then n = n + 1 end
  end
  return n
end)())

p("depth", (function()
  local function depth()
    local n = 0
    local function rec() n = n + 1; pcall(rec) end
    pcall(rec)
    return n
  end
  local d0 = depth()
  return depth() == d0
end)())

p("err", (function()
  local function f(x) if x % 2 == 0 then error("even") end return x end
  local n = 0
  for i = 1, 100000 do
    local a = pcall(f, i)
    if not a then n = n + 1 end
  end
  return n
end)())

p("sideexit", (function()
  local t = {}
  for i = 1, 100000 do t[i] = i end
  local n = 0
  for i = 1, 100000 do
    local ok, v = pcall(function() return t[i] end)
    if ok and v ~= i then n = n + 1 end
  end
  return n
end)())

p("cowrap", (function()
  local n = 0
  for i = 1, 1000 do
    local ok, v = pcall(function() return coroutine.wrap(function() return i end)() end)
    if ok and v == i then n = n + 1 end
  end
  return n
end)())
