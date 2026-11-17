--! §4.1 JIT alias analysis with 5.4 integer table keys (ADR-001b).
--! Stock 2.1 records every integer hash key as a float, and lj_opt_mem.c
--! asks irt_isnum(key) to mean "this key may be an array index or change
--! the table length". This fork keeps hash keys as IRT_INT/IRT_I64, so a
--! NEWREF/HSTORE with an int key was mistaken for a string key:
--!  - a load from a fresh table was folded to nil although an int-key push
--!    had filled that slot (deltablue removeFirst: `local e = t[#t]`);
--!  - #t was forwarded across `t[k] = nil` for an int key in the hash part.
--! Mode A compares with PUC, mode B the JIT with the interpreter.
local N = 3000

-- Push into a fresh table, read back through #t.
local function p1(x) local t = {}; t[#t+1] = x; return t[#t] end
local bad, sum = 0, 0
for i = 1, N do local v = p1(i); if v ~= i then bad = bad + 1 end; sum = sum + (v or 0) end
print("fresh-push-load", bad, sum)

-- #t after storing nil into an int key that lives in the hash part.
local tabs = {}
for i = 1, N do local t = {1, 2, 3, a = 1, b = 2, c = 3}; t[4] = 4; tabs[i] = t end
bad = 0
local lens = 0
for i = 1, N do
  local t = tabs[i]
  local n1 = #t
  t[4] = nil
  local n2 = #t
  if n2 ~= 3 or n1 ~= 4 then bad = bad + 1 end
  lens = lens + n2
end
print("len-across-int-store", bad, lens)

-- The same with a non-constant key and with the pop idiom.
bad = 0
for i = 1, N do
  local t = {1, 2, 3, a = 1, b = 2, c = 3}
  local k = 4
  t[k] = 4
  local n1 = #t
  t[k] = nil
  if #t ~= 3 or n1 ~= 4 then bad = bad + 1 end
end
print("len-var-key", bad)
bad = 0
for i = 1, N do
  local t = {}
  t[#t+1] = i; t[#t+1] = i + 1
  local a = t[#t]; t[#t] = nil
  local b = t[#t]; t[#t] = nil
  if a ~= i + 1 or b ~= i or #t ~= 0 then bad = bad + 1 end
end
print("pop-idiom", bad)

-- Loads from a fresh table with an int key that an earlier store moved into
-- the hash part (rehash by a string NEWREF).
local function p3(x)
  local t = {x, x, x, x, x, x, x, x}
  t[1] = nil; t[2] = nil; t[3] = nil; t[4] = nil; t[5] = nil; t[6] = nil; t[7] = nil
  t.a = 1
  return t[8]
end
bad = 0
for i = 1, N do if p3(i) ~= i then bad = bad + 1 end end
print("fresh-rehashed-load", bad)

-- Template tables with int64 constant keys (the TDUP const-fold path must
-- decode an IR_KINT64 key as a 5.4 integer, not as FFI cdata).
bad = 0
for i = 1, N do
  local t = {[1099511627776] = 7, a = 1}
  if t[1099511627776] ~= 7 then bad = bad + 1 end
end
print("tdup-widened-key", bad)
bad = 0
for i = 1, N do
  local t = {[4611686018427387904] = 7, a = 1}
  if t[4611686018427387904] ~= 7 then bad = bad + 1 end
end
print("tdup-boxed-key", bad)

-- A store through a variable int64 key must invalidate a load of the same
-- key written as a constant (box constant vs. IRT_I64 ref are one key type).
local ks, ts = {}, {}
for i = 1, N do ks[i] = 4611686018427387904; local t = {}; t[4611686018427387904] = 0; ts[i] = t end
bad = 0
for i = 1, N do
  local t, k = ts[i], ks[i]
  local a = t[4611686018427387904]
  t[k] = 1
  local b = t[4611686018427387904]
  if a ~= 0 or b ~= 1 then bad = bad + 1 end
end
print("i64-key-alias", bad)
