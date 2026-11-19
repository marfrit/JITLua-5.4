-- Array parts above 2^28 and 2^29 slots (LJ_GC64: the limit is 2^31-1).
-- An index of 2^29 or more times 8 does not fit 32 bits, and a constant index
-- of 2^28 or more times 8 does not fit a signed 32 bit displacement: the
-- interpreter and the compiled code must scale the index in 64 bits. Run with
-- -joff and -jon. Needs about 4.3 GiB; skipped when less than 6 GiB is
-- available.
local newtab = require("table.new")
local function avail_kb()
  local f = io.open("/proc/meminfo")
  if not f then return nil end
  local s = f:read("a"); f:close()
  return tonumber(s:match("MemAvailable:%s*(%d+)"))
end
local kb = avail_kb()
if os.getenv("ARRAY_HUGE") == "0" or (kb and kb < 6 * 1024 * 1024) then
  print("array-huge: SKIP (needs about 4.3 GiB, MemAvailable " .. tostring(kb) .. " kB)")
  return
end
local N = 2^29 + 16
local ok, t = pcall(newtab, N, 0)
if not ok then
  print("array-huge: SKIP (" .. tostring(t) .. ")")
  return
end
local fails = 0
local function check(what, got, want)
  if got ~= want then
    fails = fails + 1
    print("FAIL " .. what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
  end
end
local k = (1 << 29) + 3
t[0] = "zero"; t[1] = "one"; t[2] = "two"; t[3] = "low"

-- Variable index, interpreter paths (TGETV/TSETV) against the C API paths.
t[k] = "high"
check("t[3] after t[k] store", t[3], "low")
check("t[k]", t[k], "high")
check("rawget(t, k)", rawget(t, k), "high")
rawset(t, k + 1, "raw")
check("t[k+1] after rawset", t[k + 1], "raw")
check("t[4] after rawset", t[4], nil)

-- Constant index in hot functions: 2^29 (8*k wraps to 0) and 2^28+2 (8*k has
-- bit 31 set).
local function setc(t, v) t[536870912] = v end
local function getc(t) return t[536870913] end
local function setd(t, v) t[268435458] = v end
local function getd(t) return t[268435458] end
t[536870913] = "c1"
local r, d
for i = 1, 300 do setc(t, i); r = getc(t); setd(t, -i); d = getd(t) end
check("const 2^29 store", t[536870912], 300)
check("const 2^29+1 load", r, "c1")
check("const 2^28+2 store", rawget(t, 268435458), -300)
check("const 2^28+2 load", d, -300)
check("t[0] untouched", t[0], "zero")
check("t[1] untouched", t[1], "one")
check("t[2] untouched", t[2], "two")

-- Variable index in a hot loop.
local s = 0
for rep = 1, 100 do
  for i = k + 5, k + 12 do t[i] = i - k end
  for i = k + 5, k + 12 do s = s + t[i] end
end
check("hot loop sum", s, 6800)
check("t[5] untouched", t[5], nil)
check("t[12] untouched", t[12], nil)
check("t[k+12]", t[k + 12], 12)

-- Traversal and the library paths at a high index.
local nk, nv = next(t, k + 11)
check("next key", nk, k + 12)
check("next value", nv, 12)
local cnt, last = 0, nil
for key in pairs(t) do cnt = cnt + 1; last = key end
check("pairs count", cnt, 17)
check("pairs last key", last, k + 12)
check("unpack", select(2, table.unpack(t, k + 5, k + 7)), 6)
check("concat", table.concat(t, ",", k + 5, k + 7), "5,6,7")
table.move(t, k + 5, k + 7, k + 20)
check("move", t[k + 22], 7)
check("move left t[22] alone", t[22], nil)
t[N] = "end"; t[N - 1] = "end1"
local len = #t  -- any border is legal: 3 and N both are
check("#t is a border", t[len] ~= nil and t[len + 1] == nil, true)
check("t[N]", t[N], "end")
if fails > 0 then
  print("array-huge: " .. fails .. " FAILED")
  os.exit(1)
end
print("array-huge: ok (" .. (jit and jit.status() and "jit on" or "jit off") .. ")")
