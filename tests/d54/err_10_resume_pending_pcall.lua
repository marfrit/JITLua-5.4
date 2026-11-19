--! §2.3/§4.3: a coroutine that yields inside pcall frames and is resumed
--! again. PUC 5.4 sets the C-call count of the resumed thread to the
--! resumer's count plus one on every resume; the pcall frames that were
--! pending at the yield no longer count (their C levels are gone) and do not
--! take anything back when they return. A resume that overwrites the count
--! while those frames still decrement it on return drives it below zero: the
--! next pcall in the coroutine then fails with "C stack overflow".
--! Only deltas against the top-level depth are printed, like err_06.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local function depth()
  local n = 0
  local function rec() n = n + 1; pcall(rec) end
  pcall(rec)
  return n
end

local d0 = depth()
local function d(v) return v - d0 end

local function nest(k)
  if k == 0 then coroutine.yield("y") return "done" end
  local ok, v = pcall(nest, k - 1)
  assert(ok, v)
  return v
end

-- yield inside k pcall frames, resume, let them return, use pcall again
for _, k in ipairs{1, 2, 3, 5, 10, 50, 150} do
  local co = coroutine.wrap(function()
    local a = depth()
    local r = nest(k)
    local ok, e = pcall(function() return "fine" end)
    return r, ok, e, a - depth()
  end)
  p("wrap yield", k, co())
  p("wrap again", k, pcall(co))
end
for _, k in ipairs{1, 5, 10, 150} do
  local co = coroutine.create(function()
    local a = depth()
    local r = nest(k)
    local ok, e = pcall(function() return "fine" end)
    return r, ok, e, a - depth()
  end)
  p("resume yield", k, coroutine.resume(co))
  p("resume again", k, coroutine.resume(co))
end

-- the depth seen inside the pending frames after the resume
do
  local co = coroutine.wrap(function()
    return pcall(function()
      local a = depth()
      coroutine.yield()
      return a - depth()
    end)
  end)
  co()
  p("inside", co())
end

-- an error raised after the resume is caught by a pending frame
do
  local co = coroutine.wrap(function()
    local a = depth()
    local ok, e = pcall(function()
      local ok2, e2 = pcall(function() coroutine.yield(1); error("inner", 0) end)
      coroutine.yield(2)
      error(tostring(e2) .. "+outer", 0)
    end)
    return ok, e, a - depth()
  end)
  p("err", co()); p("err", co()); p("err", co())
end

-- resumed from a deeper and from a shallower nesting than it yielded at
do
  local co = coroutine.wrap(function()
    while true do nest(3); coroutine.yield(depth()) end
  end)
  local function at(n, f)
    if n == 0 then return f() end
    return select(2, pcall(at, n - 1, f))
  end
  p("first", co())
  p("deep", d(at(20, co)))
  p("next", co())
  p("shallow", d(co()))
  p("deep2", d(at(40, function() co(); return co() end)))
  p("next", co())
  p("shallow2", d(co()))
end

-- many cycles: nothing accumulates in either direction
do
  local co = coroutine.wrap(function()
    for i = 1, 300 do nest(4) end
    return depth()
  end)
  local r
  for i = 1, 301 do r = co() end
  p("cycles", d(r))
end

p("main", d(depth()))
