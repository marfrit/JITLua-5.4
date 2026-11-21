--! §math math.min/math.max with integers next to floats in compiled code:
--! the result is the winning argument with its own subtype (PUC lmathlib.c
--! pushes the argument), a tie and a NaN keep the earlier one. The loops are
--! compiled: an aborted or stitched trace in the marked loops fails the test (mixed lists
--! used to abort every trace, the loop then ran in the interpreter).
local jit = rawget(_G, "jit")
local aborts, watching = 0, false
if jit and jit.status and jit.status() and jit.attach then
  local ok, util = pcall(require, "jit.util")
  local root = {}  -- only root traces: a side trace may run on into print
  jit.attach(function(what, tr, func, pc, otr)
    if what == "start" then
      root[tr] = watching and otr == nil
    elseif root[tr] and what == "abort" then
      aborts = aborts + 1
    elseif root[tr] and what == "stop" and ok and
	   util.traceinfo(tr).linktype == "stitch" then
      aborts = aborts + 1  -- the call was left to the interpreter
    end
  end, "trace")
end
local function show(v) return tostring(v) .. ":" .. tostring(math.type(v)) end

-- hot, flat loops that must compile
watching = true
do
  local s = 0.0
  for i = 1, 1000 do s = s + math.max(i * 0.5 - 10, 0) end
  print("max(float, 0)", show(s))
  s = 0.0
  for i = 1, 1000 do s = s + math.min(1, math.max(0, i * 0.01 - 2)) end
  print("clamp", show(s))
  local r
  for i = 1, 300 do r = math.max(i, 0.5) end print("max(int, float)", show(r))
  for i = 1, 300 do r = math.min(i, 0.5) end print("min(int, float)", show(r))
  for i = 1, 300 do r = math.max(0.5, i, 2.5) end print("max of three", show(r))
  for i = 1, 300 do r = math.min(i + 0.5, 7, 9.5, i) end print("min of four", show(r))
end
watching = false

-- every pairing, compiled per pair
local vals = {1, 1.0, 2, 2.5, -0.0, 0, 0.0, 0/0, -3, -3.5, 2147483647, 2147483647.0,
	      -2147483648, 1e300, -1e300, math.huge, -math.huge}
for i = 1, #vals do
  local line = {}
  for j = 1, #vals do
    local a, b = vals[i], vals[j]
    local mn, mx, m3
    for k = 1, 60 do mn = math.min(a, b); mx = math.max(a, b); m3 = math.max(b, a, b) end
    line[#line + 1] = show(mn) .. "/" .. show(mx) .. "/" .. show(m3)
  end
  print(i, table.concat(line, " "))
end

-- a compiled loop meets the other outcome and other kinds
local mix = {5, 0.5, 7, 7.0, 2.5, 3, 0/0, -1, "9", 1 << 40}
local out = {}
for i = 1, 2000 do
  local a = mix[(i % 3 == 0 and i > 600) and (i % #mix + 1) or 1]
  local b = mix[(i > 1200) and ((i * 7) % #mix + 1) or 2]
  local ok, r = pcall(math.max, a, b)
  local ok2, r2 = pcall(math.min, b, a, 6)
  if i % 97 == 0 or i > 1990 then
    out[#out + 1] = (ok and show(r) or "err") .. "|" .. (ok2 and show(r2) or "err")
  end
end
print(table.concat(out, " "))
-- the winner flips inside one loop
local s, t = 0, 0.0
for i = 1, 1000 do
  local v = math.max(i % 7 - 3.5, 0)
  if math.type(v) == "integer" then s = s + 1 else t = t + v end
end
print(s, t)
if aborts > 0 then error("aborted or stitched traces in the loops that must compile: " .. aborts) end
