--! modes: B,R
--! A compiled trace must follow an _ENV change that happens where a trace
--! flush is not possible: inside a __gc finalizer (lj_trace_flushall refuses
--! there) or from a hook while a trace is being recorded. The non-table env
--! value of a closure is baked into its trace, so the trace has to check the
--! value itself instead of relying on a flush.
--! -joff gives the right answers for all of them.
local pr = print
local function mk(e)
  _ENV = e
  return function() local s; for i = 1, 300 do s = x end; return s end
end
local function envidx(f)  -- index of the synthesized _ENV upvalue
  for i = 1, 20 do
    local name = debug.getupvalue(f, i)
    if name == nil then return nil end
    if name == "_ENV" then return i end
  end
end
debug.setmetatable(0, {__index = function(n, k) return n .. ":" .. k end})

-- (1) debug.setupvalue from a finalizer, non-table -> non-table.
local A = mk(5)
pr("A", A())
setmetatable({}, {__gc = function() debug.setupvalue(A, envidx(A), 7) end})
collectgarbage(); collectgarbage()
pr("gc-setupvalue", A())

-- (2) setfenv from a finalizer, non-table -> table.
local B = mk(5)
pr("B", B())
setmetatable({}, {__gc = function() setfenv(B, {x = "fenv-in-gc"}) end})
collectgarbage(); collectgarbage()
pr("gc-setfenv", B())

-- (3) debug.upvaluejoin from a finalizer, non-table -> non-table.
local C, C2 = mk(5), mk(9)
pr("C", C())
setmetatable({}, {__gc = function()
  debug.upvaluejoin(C, envidx(C), C2, envidx(C2))
end})
collectgarbage(); collectgarbage()
pr("gc-upvaluejoin", C())

-- (4) the finalizer itself calls the function after the change.
local D = mk(5)
pr("D", D())
local seen
setmetatable({}, {__gc = function()
  debug.setupvalue(D, envidx(D), 6); seen = D()
end})
collectgarbage(); collectgarbage()
pr("gc-call", seen, D())

-- (5) a count hook changes the env while the loop is hot / being recorded.
local E = mk(5)
local n = 0
debug.sethook(function()
  n = n + 1
  if n == 3 then debug.setupvalue(E, envidx(E), 8) end
end, "", 40)
local e1, e2 = E(), E()
debug.sethook()
pr("hook", e1, e2, E())

-- (6) siblings with the same and with different non-table envs keep apart.
local F1, F2, F3 = mk(11), mk(11), mk(22)
for i = 1, 3 do pr("siblings", F1(), F2(), F3()) end

debug.setmetatable(0, nil)
