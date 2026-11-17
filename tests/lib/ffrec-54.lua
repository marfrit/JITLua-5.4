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
local vals = { 1, -7, 2.5, -2.5, "s", true, nil, {}, W, B, -W, -B, print, 1/0, -(2^31) }

local function type_loop()
  local n, s = #vals, {}
  for i = 1, 300 do
    local v = vals[(i % 12) + 1]
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

local loop_fns = {type_loop, rawlen_loop, abs_loop, floor_loop, abs_wide_loop, floor_wide_loop}
-- line of the `for` relative to the function line
local loop_ofs = {[type_loop] = 3, [rawlen_loop] = 3, [abs_loop] = 3, [floor_loop] = 2, [abs_wide_loop] = 2, [floor_wide_loop] = 2}
local loop_set = {}
for _, fn in ipairs(loop_fns) do loop_set[fn] = true end
local trace_starts, loop_lines, loop_starts, stitched = {}, {}, {}, {}
local trace_handler
if jit and jit.status() then
  local ju = require("jit.util")
  for _, fn in ipairs(loop_fns) do
    loop_starts[fn] = ju.funcinfo(fn).linedefined + loop_ofs[fn]
  end
  trace_handler = function(what, tr, func, pc, otr, oex)
    if what == "start" then
      trace_starts[tr] = { func = func, line = ju.funcinfo(func, pc).currentline, stitch = (oex == "stitch") }
    elseif what == "stop" then
      local st = trace_starts[tr]
      if st and loop_set[st.func] then
        if ju.traceinfo(tr).linktype == "loop" then loop_lines[st.func] = st.line end
        if st.stitch then stitched[st.func] = (stitched[st.func] or 0) + 1 end
      end
    end
  end
  jit.attach(trace_handler, "trace")
end

local s = type_loop()
eq("type-number", s.number, 8 * 25)  -- 1, -7, 2.5, -2.5, W, B, -W, -B, each 25 times
eq("type-string", s.string, 25)
eq("type-boolean", s.boolean, 25)
eq("type-nil", s["nil"], 25)
eq("type-table", s.table, 25)
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
local fw, fwt = floor_wide_loop()
eq("floor-wide", fw, 2 * 45150)
eq("floor-wide-type", fwt, "integer")
if jit and jit.status() then
  for _, fn in ipairs(loop_fns) do
    if loop_lines[fn] ~= loop_starts[fn] then
      fails = fails + 1
      print("FAIL hot loop did not compile to a root loop trace at line " .. loop_starts[fn] .. " (got " .. tostring(loop_lines[fn]) .. ")")
    end
    if stitched[fn] then
      fails = fails + 1
      print("FAIL stitch trace recorded for the loop at line " .. loop_starts[fn])
    end
  end
  jit.attach(trace_handler)
end
print(fails == 0 and "ffrec-54 ok" or ("ffrec-54 FAILED " .. fails))
if fails ~= 0 then os.exit(1) end
