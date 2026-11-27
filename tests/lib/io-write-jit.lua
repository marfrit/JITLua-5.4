-- Regression test for the io.write fast-function recorder.
--
-- Hot loops that write strings, integers, floats and a boxed int64 must
-- compile to root loop traces: before the fix, any float argument aborted
-- the trace with "bad argument type". The output must equal the exact text
-- the interpreter produces: 5.4 io.write renders floats with "%.14g" (no
-- ".0" suffix), not with tostring rules, and renders integers as exact
-- decimals. The expected text is built independently with string.format.
-- Covers -0.0, math.huge, constant float arguments (constant folding),
-- f:write(x) and assert(io.write(...)). A widened 47-bit integer and a boxed
-- int64 are written in a third hot loop, which must compile too: io.write and
-- file:write take an IRT_I64 argument (exact decimal through lj_ir_tostr).
-- Exits 1 on any mismatch or, under -jon, if any of the three hot loops does
-- not get a root loop trace. Run with -joff and -jon.
local fails = 0
local function eq(name, got, want)
  if got ~= want then fails = fails + 1; print("FAIL " .. name, got, want) end
end

local N = 2000
local NZ = -0.0
local tmpfile = os.tmpname()

-- Attach the trace handler before running so the first recording is seen.
local trace_ok, trace_starts, trace_handler = {}, {}, nil
if jit and jit.status() then
  local ju = require("jit.util")
  trace_handler = function(what, tr, func, pc, otr, oex)
    if what == "start" then
      trace_starts[tr] = { stitch = (oex == "stitch") }
    elseif what == "stop" then
      local st = trace_starts[tr]
      if st and not st.stitch then
        local info = ju.traceinfo(tr)
        if info.linktype == "loop" and info.link == tr then
          trace_ok[func] = true
        end
      end
    end
  end
  jit.attach(trace_handler, "trace")
end

local f = assert(io.open(tmpfile, "w"))
io.output(f)

local w40 = 1 << 40        -- widened integer
local big = (1 << 50) + 3  -- boxed int64

local function loop_io_write()
  for i = 1, N do
    assert(io.write("i", i, " ", i * 0.5, " ", 2.0, " ", NZ, " ",
		    math.huge, " ", -0.0, "\n"))
  end
end

local function loop_f_write()
  for i = 1, N do
    assert(f:write("b", i, " ", i * 0.25, " ", i / 1, " ", NZ, "\n"))
  end
end

local mini, maxi = math.mininteger, math.maxinteger
local function loop_int64_edges()
  local acc = (1 << 31) + 5      -- int64 ref, value drops back into int32
  for i = 1, N do
    acc = acc - 1
    io.write("e", mini, " ", maxi, " ", 1125899906842627, " ", acc, "\n")
  end
end

local function loop_int64()
  for i = 1, N do
    io.write("w", w40 + i, " ", big + i, " ", -big - i, "\n")
    f:write("v", big * 2 + i, "\n")
  end
end

loop_io_write()
loop_f_write()
loop_int64()
loop_int64_edges()
io.output():flush()
io.output(io.stdout)
f:close()

local rf = assert(io.open(tmpfile, "r"))
local captured = rf:read("*a")
rf:close()
os.remove(tmpfile)

if trace_handler then jit.attach(trace_handler) end  -- detach

local fmt = function(x) return string.format("%.14g", x) end
local expected = {}
for i = 1, N do
  expected[#expected + 1] = "i" .. i .. " " .. fmt(i * 0.5)
    .. " 2 -0 inf -0\n"
end
for i = 1, N do
  expected[#expected + 1] = "b" .. i .. " " .. fmt(i * 0.25) .. " "
    .. fmt(i / 1) .. " -0\n"
end
for i = 1, N do
  expected[#expected + 1] = "w" .. (w40 + i) .. " " .. (big + i) .. " "
    .. (-big - i) .. "\n" .. "v" .. (big * 2 + i) .. "\n"
end
-- Literal text for the edge loop, independent of the int64 formatter.
local acc = 2147483653
for i = 1, N do
  acc = acc - 1
  expected[#expected + 1] = "e-9223372036854775808 9223372036854775807 "
    .. "1125899906842627 " .. string.format("%d", acc) .. "\n"
end
eq("output", captured, table.concat(expected))
-- Spot checks against literals (the loops above share the formatter).
eq("literal w1", captured:match("\nw1099511627777 [^\n]*"),
   "\nw1099511627777 1125899906842628 -1125899906842628")
eq("literal v1", captured:match("\nv2251799813685255\n"),
   "\nv2251799813685255\n")

if jit and jit.status() then
  if not trace_ok[loop_io_write] then
    fails = fails + 1
    print("FAIL io.write loop did not compile to a root loop trace")
  end
  if not trace_ok[loop_f_write] then
    fails = fails + 1
    print("FAIL f:write loop did not compile to a root loop trace")
  end
  if not trace_ok[loop_int64] then
    fails = fails + 1
    print("FAIL int64 write loop did not compile to a root loop trace")
  end
  if not trace_ok[loop_int64_edges] then
    fails = fails + 1
    print("FAIL int64 edge loop did not compile to a root loop trace")
  end
  if fails == 0 then print("io-write-jit ok") end
else
  if fails == 0 then print("io-write-jit ok (interpreter)") end
end

if fails ~= 0 then os.exit(1) end
