--! §2.3/§4.3: closing a coroutine runs its pending __close handlers with the
--! closer's C-call nesting (PUC lua_closethread sets nCcalls to the closer's
--! count; the C call into the handler adds the other level), so the usable
--! pcall depth inside the handler drops by the closer's nesting plus one.
--! The absolute depth differs from PUC, so print only the deltas.
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

-- coroutine.close from inside k nested pcall frames
local function close_at(k)
  local got
  local co = coroutine.create(function()
    local x <close> = setmetatable({}, {__close = function() got = depth() end})
    coroutine.yield()
  end)
  coroutine.resume(co)
  local function go(n)
    if n <= 0 then coroutine.close(co) else pcall(go, n - 1) end
  end
  go(k)
  return d(got)
end
p("close_at0", close_at(0))
p("close_at1", close_at(1))
p("close_at2", close_at(2))
p("close_at3", close_at(3))

-- an error propagating out of coroutine.wrap closes the coroutine's pending
-- slots from inside the same k nested pcall frames
local function wrap_err_at(k)
  local got
  local w = coroutine.wrap(function()
    local x <close> = setmetatable({}, {__close = function() got = depth() end})
    error("boom")
  end)
  local function go(n)
    if n <= 0 then pcall(w) else pcall(go, n - 1) end
  end
  go(k)
  return got and d(got) or "none"
end
p("wrap_err0", wrap_err_at(0))
p("wrap_err1", wrap_err_at(1))
p("wrap_err2", wrap_err_at(2))
p("wrap_err3", wrap_err_at(3))
