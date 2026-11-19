--! modes: B,R
--! Traces are keyed on the prototype, not on the closure: a sibling closure
--! of the same proto must not run a trace recorded for another closure's _ENV.
--! (1) non-table env baked in as a constant: a sibling closure reads the
--! recorded env instead of its own ("num:x" instead of "tableD").
--! (2) table env + a nil-env sibling: the table path's unguarded
--! `FLOAD FUNC_ENV` dereferences NULL -> SIGSEGV under -jon (last, so the
--! earlier mismatches are visible before the abort).
--! (3) the C-API/debug env setters (setupvalue, setfenv, upvaluejoin) change
--! the env without the trace flush that `_ENV = v` does, so a compiled trace
--! keeps the old env.
--! -joff gives the right answers for all of them.
local pc, pr = pcall, print
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

-- (1) sibling envs: two same-shape tables, then a non-table env, then a
-- table env again (all siblings of one proto).
local A, B = mk({x = "A"}), mk({x = "B"})
pr("same-shape", A(), B())
debug.setmetatable(0, {__index = function(_, k) return "num:" .. k end})
local C, D = mk(5), mk({x = "tableD"})
pr("num", C())
pr("tableD", D())

-- (3) setupvalue on _ENV after a trace was compiled with a number env.
local G = mk(7)
pr("num7", G())
debug.setupvalue(G, envidx(G), {x = "back"})
pr("setupvalue", G())

-- (3b) setfenv on the same closure, after a fresh trace.
local H = mk(9)
pr("num9", H())
setfenv(H, {x = "setfenv"})
pr("setfenv", H())

-- (3c) debug.upvaluejoin on _ENV after a fresh trace.
local I = mk(11)
pr("num11", I())
local joined = {x = "joined"}
local anon = function() return joined end
debug.upvaluejoin(I, envidx(I), anon, 1)
pr("upvaluejoin", I())

-- (2) table env then a nil-env sibling: this one SIGSEGVs on the unfixed tree,
-- so it is last: the earlier mismatches are visible before the abort.
local E, F = mk({x = "tableE"}), mk(nil)
pr("tableE", E())
pr("nil-sibling", pc(F))

debug.setmetatable(0, nil)
