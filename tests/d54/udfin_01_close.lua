--! §4.4 userdata finalizers installed while lua_close runs must not run.
--! PUC 5.4 luaC_checkfinalizer registers nothing when the closing flag is set
--! (GCSTPCLS): an object that gets __gc during a finalizer of lua_close is
--! freed without a second call. LuaJIT registers finalizable userdata when
--! the collector separates them (not at setmetatable time); during lua_close
--! that separation ran again after the finalizers, so a finalizer that
--! creates a new finalizable userdata, or gives __gc to an existing one, was
--! called again, round after round, until the close loop bound.
--! newproxy is a LuaJIT extension, so this file has no PUC arm (modes B,R:
--! JIT on and off, and dump/reload, must agree and exit 0).
--! A finalizer that sees a second round exits 3; one that sees the attached
--! __gc exits 4, so the hang-free failure shows in the exit status.
--! modes: B,R
--! timeout: 20
local function fail(code, what)
  io.write("FAIL: ", what, "\n")
  os.exit(code)
end

-- newproxy is a 5.1 leftover behind -DLUAJIT_ENABLE_51COMPAT: without the
-- switch this file has no way to make a userdata, so it reports a skip and the
-- compat ci-box stage runs it again against the switched build.
if newproxy == nil then
  print("skip: needs newproxy")
  os.exit(0)
end

-- A finalizable userdata whose finalizer creates another one with the same
-- __gc, and gives a reachable userdata a __gc metatable on the way.
local rounds = 0
local attached = 0
local keep            -- declared first: the finalizer sees the local

local function attached_fin()
  attached = attached + 1
  fail(4, "userdata given __gc during close was finalized")
end

local function fin()
  rounds = rounds + 1
  if rounds > 1 then
    fail(3, "userdata finalizer re-entered during close (round " .. rounds .. ")")
  end
  getmetatable(keep).__gc = attached_fin
  local p = newproxy(true)
  getmetatable(p).__gc = fin
end

-- Reachable across the close: __gc must not be registered for it.
keep = newproxy(true)
_G.gc_keep = keep

-- Collectable: finalized once by lua_close, then never again.
local victim = newproxy(true)
getmetatable(victim).__gc = fin
victim = nil

assert(rounds == 0, "finalizers must not run before close")
print("udfin_01: main chunk ends, close runs the finalizer once")
