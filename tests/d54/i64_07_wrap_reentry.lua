--! §3.4.1: integer wraparound at loop exit under side-trace replay. In 5.4
--! integer arithmetic wraps modulo 2^64. A hot loop whose accumulator
--! overflows the 47-bit inline form (box) and then wraps back into the
--! int32 range exits the trace with the wrapped value; a side trace that
--! replays that snapshot sees the value in its canonical (int32) encoding.
--! Every case ends with p = 0 mod 2^64. The loop runs three times with the
--! same start value so the loop trace re-enters and the exit chain runs the
--! side trace. Fixed output only.
local function s(name, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(name, table.concat(t, ","))
end
local function ty(x) return math.type(x) or "?" end

local function inner(p0, N)
  local p = p0
  for k = 1, 3 do
    for i = 1, N do p = p * 2 end
    if k < 3 then p = p0 end
  end
  return p
end

local p
p = inner(1, 64);          s("wrap-int32", p, ty(p))    -- wraps at i=64
p = inner(1 << 57, 70);    s("wrap-box", p, ty(p))      -- box start, wraps at i=7
p = inner(1 << 40, 70);    s("wrap-mixed", p, ty(p))    -- int32 start, 47w mid, wraps at i=24
p = inner(1 << 44, 50);    s("wrap-47w", p, ty(p))      -- int32 start, 47w at i=3, wraps at i=20
