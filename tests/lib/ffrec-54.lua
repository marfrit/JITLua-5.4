-- Acceptance test for the re-enabled fast-function recorders with Lua 5.4
-- semantics: type(), rawlen(), math.abs(), math.floor(), math.ceil(). Each
-- hot loop must compile to a root loop trace (no stitch around a C call),
-- and the compiled results must equal the interpreter's, including
-- math.type() of the results. Exits 1 on any mismatch. Run with -joff and -jon.
local fails = 0
local function eq(name, got, want)
  if got ~= want then fails = fails + 1; print("FAIL " .. name, got, want) end
end
local W = (1 << 40) + 3            -- widened inline int64
local B = (1 << 50) + 3            -- boxed int64
-- io.stdout is a real userdata: its load guard admits a boxed int64 (same
-- type tag), so the type() recorder must guard the udtype as well.
local vals = { 1, -7, 2.5, -2.5, "s", true, nil, {}, W, B, -W, -B, print, 1/0, -(2^31), io.stdout }

local function type_loop()
  local n, s = #vals, {}
  for i = 1, 320 do
    local v = vals[(i % 16) + 1]
    local t = type(v)
    s[t] = (s[t] or 0) + 1
  end
  return s
end
local function rawlen_loop()
  local t, str = {1, 2, 3, 4, 5}, "hello"
  local a, b = 0, 0
  for i = 1, 300 do
    a = a + rawlen(t); b = b + rawlen(str)
    if i % 50 == 0 then t[#t + 1] = i end
  end
  return a, b
end
local function abs_loop()
  local si, sf, ti, tf = 0, 0.0, "", ""
  for i = 1, 300 do
    local a = math.abs(-i)
    local b = math.abs(i - 150)
    local c = math.abs(-i * 0.5)
    si = si + a + b; sf = sf + c
    if i == 300 then ti = math.type(a) .. math.type(b); tf = math.type(c) end
  end
  return si, sf, ti, tf
end
local function floor_loop()
  local s, sc, tf, tc, tfi = 0, 0, "", "", ""
  for i = 1, 300 do
    local f = math.floor(i * 0.3)
    local c = math.ceil(i * 0.3)
    local g = math.floor(i)
    s = s + f; sc = sc + c + g
    if i == 300 then tf = math.type(f); tc = math.type(c); tfi = math.type(g) end
  end
  return s, sc, tf, tc, tfi
end
local function abs_wide_loop()
  local s, t = 0, ""
  for i = 1, 300 do
    local a = math.abs(-W - i)
    local b = math.abs(-B - i)
    s = s + (a - W) + (b - B)
    if i == 300 then t = math.type(a) .. math.type(b) end
  end
  return s, t
end
local function abs_min_loop()  -- -(-2^31) leaves int32: the exit must handle it
  local s, t = 0, ""
  for i = 1, 300 do
    local v = (i == 200) and -2147483648 or -i
    local a = math.abs(v)
    s = s + a
    if i == 200 then t = math.type(a) end
  end
  return s, t
end
local function floor_wide_loop()  -- integer args pass through unchanged
  local s, t = 0, ""
  for i = 1, 300 do
    local f = math.floor(W + i) + math.ceil(B + i)
    s = s + (f - W - B)
    if i == 300 then t = math.type(f) end
  end
  return s, t
end

-- Recorded on the real userdata first: the udata load guard alone would let
-- the boxes through and report them as "userdata".
local function type_udfirst_loop()
  local tv, nn, nu = { io.stdout, io.stdout, io.stdout, io.stdout, B, B, B, B }, 0, 0
  for i = 1, 400 do
    local v = tv[(i % 8) + 1]
    if type(v) == "number" then nn = nn + 1 else nu = nu + 1 end
  end
  return nn, nu
end
local loop_fns = {type_loop, rawlen_loop, abs_loop, floor_loop, abs_wide_loop, floor_wide_loop, type_udfirst_loop}
local loop_set = {}
for _, fn in ipairs(loop_fns) do loop_set[fn] = true end
local trace_starts, loop_ok, stitched = {}, {}, {}
local trace_handler
if jit and jit.status() then
  local ju = require("jit.util")
  -- Note: this replaces any jit.v/jit.dump handler for the "trace" event.
  trace_handler = function(what, tr, func, pc, otr, oex)
    if what == "start" then
      trace_starts[tr] = { func = func, stitch = (oex == "stitch") }
    elseif what == "stop" then
      local st = trace_starts[tr]
      if st and loop_set[st.func] then
        local info = ju.traceinfo(tr)
        -- A root loop trace links to itself (a side trace linking back to
        -- the loop also says "loop", but its link is the root).
        if info.linktype == "loop" and info.link == tr then loop_ok[st.func] = true end
        if st.stitch then stitched[st.func] = (stitched[st.func] or 0) + 1 end
      end
    end
  end
  jit.attach(trace_handler, "trace")
end

local s = type_loop()
eq("type-number", s.number, 10 * 20)  -- 1, -7, 2.5, -2.5, W, B, -W, -B, 1/0, -(2^31): 20 each
eq("type-string", s.string, 20)
eq("type-boolean", s.boolean, 20)
eq("type-nil", s["nil"], 20)
eq("type-table", s.table, 20)
eq("type-function", s["function"], 20)
eq("type-userdata", s.userdata, 20)
local a, b = rawlen_loop()
eq("rawlen-tab", a, 5 * 50 + 6 * 50 + 7 * 50 + 8 * 50 + 9 * 50 + 10 * 50)
eq("rawlen-str", b, 1500)
local si, sf, ti, tf = abs_loop()
eq("abs-int", si, 45150 + (149 * 150 / 2) + (150 * 151 / 2))
eq("abs-float", sf, 45150 * 0.5)
eq("abs-int-type", ti, "integerinteger")
eq("abs-float-type", tf, "float")
local fs, fsc, ftf, ftc, ftfi = floor_loop()
local ws, wsc = 0, 0
for i = 1, 300 do ws = ws + math.floor(i * 0.3); wsc = wsc + math.ceil(i * 0.3) + i end
eq("floor-sum", fs, ws)
eq("ceil-sum", fsc, wsc)
eq("floor-type", ftf, "integer")
eq("ceil-type", ftc, "integer")
eq("floor-int-type", ftfi, "integer")
local aw, awt = abs_wide_loop()
eq("abs-wide", aw, 2 * 45150)
eq("abs-wide-type", awt, "integerinteger")
local am, amt = abs_min_loop()
eq("abs-min", am, 45150 - 200 + 2^31)
eq("abs-min-type", amt, "integer")
local un, uu = type_udfirst_loop()
eq("type-udfirst-number", un, 200)
eq("type-udfirst-userdata", uu, 200)
local fw, fwt = floor_wide_loop()
eq("floor-wide", fw, 2 * 45150)
eq("floor-wide-type", fwt, "integer")
if jit and jit.status() then
  for i, fn in ipairs(loop_fns) do
    local ju = require("jit.util")
    local where = "loop " .. i .. " (function at line " .. ju.funcinfo(fn).linedefined .. ")"
    if not loop_ok[fn] then
      fails = fails + 1
      print("FAIL " .. where .. " did not compile to a root loop trace")
    end
    if stitched[fn] then
      fails = fails + 1
      print("FAIL " .. where .. ": " .. stitched[fn] .. " stitch trace(s) recorded (a builtin fell back to a C call)")
    end
  end
  jit.attach(trace_handler)
end
print(fails == 0 and "ffrec-54 ok" or ("ffrec-54 FAILED " .. fails))
if fails ~= 0 then os.exit(1) end
