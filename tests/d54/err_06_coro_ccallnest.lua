--! §2.3/§4.3: PUC 5.4 counts the C-call nesting across coroutines: lua_resume
--! sets the new thread's count to the resumer's count plus one, so the usable
--! pcall depth inside a coroutine is lower by the resume nesting. The absolute
--! depth differs from PUC (PUC's C-call baseline is nonzero), so print only the
--! deltas against the top-level depth, like err_04.
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

p("top", d0 == d0 and 0 or 0)

local w = coroutine.wrap(function() return depth() end)
p("wrap", d(w()))

p("resume", d(select(2, coroutine.resume(coroutine.create(depth)))))

local co2 = coroutine.create(function() return depth() end)
local co1 = coroutine.create(function()
  local ok, v = coroutine.resume(co2); return v
end)
p("nest2", d(select(2, coroutine.resume(co1))))

local w2 = coroutine.wrap(function()
  local w3 = coroutine.wrap(function() return depth() end)
  return w3()
end)
p("wrap2", d(w2()))

-- resume from inside k nested pcall frames: the child loses k+1 levels
local function resume_at(k)
  local r
  local function f()
    r = select(2, coroutine.resume(coroutine.create(depth)))
  end
  local function go(n)
    if n <= 0 then f() else pcall(go, n - 1) end
  end
  go(k)
  return r
end
p("resume_at3", d(resume_at(3)))

-- a yield/resume cycle keeps the same inherited count
local co3 = coroutine.create(function()
  local a = depth()
  coroutine.yield()
  local b = depth()
  return a, b
end)
coroutine.resume(co3)
local ok, a, b = coroutine.resume(co3)
p("yieldcycle", d(a), d(b))
