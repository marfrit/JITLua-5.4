--! §6.10 return events of a Lua function that ends in a tail call to a C
--! function ("return string.sub(s, 2)"). PUC calls the C function, then
--! finishes the Lua caller (lvm.c OP_TAILCALL -> luaD_poscall), so after the C
--! function's own return event the caller gets its return event, with the C
--! function's results as the transfer values. Printed: the event sequence for
--! several callee kinds and masks, the transfer values and the line seen in
--! the caller's return event, and the same through a coroutine yield.
--! Fixed output only.
local ev
local function hook(e)
  local ar = debug.getinfo(2, "nSl")
  ev[#ev+1] = e .. ":" .. tostring(ar.name) .. "/" .. ar.what
end
local function f1 () return string.sub("abcd", 2) end
local function f2 () return tostring(12) end
local function f3 () return table.concat({"a", "b"}) end
local function f4 () return select("#", 1, 2, 3) end
local function f5 (...) return select("#", ...) end
local function f6 () return ("x"):rep(3) end
local function f7 () return pcall(type, 1) end
local function f8 () return math.max(1, 5, 3) end
local function f9 () local function g () return string.upper("q") end return g() end
local fs = {f1, f2, f3, f4, f5, f6, f7, f8, f9}
for i = 1, #fs do
  local f = fs[i]
  for _, m in ipairs{"cr", "r"} do
    ev = {}
    debug.sethook(hook, m)
    local a, b = f(1, 2)
    debug.sethook()
    table.remove(ev, 1)  -- the return event of debug.sethook
    if m == "cr" then table.remove(ev) end  -- the call event of debug.sethook
    print(i, m, tostring(a), tostring(b), table.concat(ev, " "))
  end
end

-- The transfer values and the current line in the caller's return event.
do
  local out = {}
  local function tf () return string.rep("ab", 2), "unused" end
  local function tg ()
    return select(2, "p", "q", "r")
  end
  debug.sethook(function (e)
    local ar = debug.getinfo(2, "nSlr")
    if e ~= "return" or ar.what ~= "Lua" then return end
    local v = {}
    for k = ar.ftransfer, ar.ftransfer + ar.ntransfer - 1 do
      local nm, val = debug.getlocal(2, k)
      v[#v+1] = tostring(val)
    end
    out[#out+1] = tostring(ar.name) .. " line=" .. ar.currentline ..
      " ntr=" .. ar.ntransfer .. " [" .. table.concat(v, " ") .. "]"
  end, "r")
  tf(); tg()
  debug.sethook()
  for i = 1, #out do print("tr", out[i]) end
end

-- A tail call to a C function that errors: no return event for the caller.
do
  ev = {}
  local function fe () return string.rep() end
  debug.sethook(hook, "cr")
  local ok = pcall(fe)
  debug.sethook()
  table.remove(ev, 1); table.remove(ev)
  print("err", ok, table.concat(ev, " "))
end

-- The yield as the tail call: the yield returns when the coroutine is
-- resumed, then the body returns.
do
  local tr = {}
  local co = coroutine.create(function (x) return coroutine.yield(x + 1) end)
  debug.sethook(co, function (e)
    local ar = debug.getinfo(2, "nS")
    tr[#tr+1] = e .. ":" .. tostring(ar.name) .. "/" .. ar.what
  end, "cr")
  print("co", coroutine.resume(co, 1))
  print("co", coroutine.resume(co, "a", "b"))
  debug.sethook(co)
  print("co", table.concat(tr, " "))
end
