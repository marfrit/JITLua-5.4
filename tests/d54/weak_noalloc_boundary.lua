--! Parity boundary for weak tables: a loop that only reads a weak table and
--! allocates nothing never runs the GC, so the entry is never collected (same
--! on PUC 5.4 and on -joff). A loop that allocates one collectable key per
--! iteration lets the GC clear them. Bounded so both terminate; only the
--! outcome is printed so the arms agree regardless of GC pacing.
local LIMIT = 200000
local x = setmetatable({[1] = {}}, {__mode = "kv"})
local A = 0
while x[1] do
  if A >= LIMIT then break end
  A = A + 1
end
print("noalloc", x[1] == nil and "nil" or "alive", A)

local LIMIT2 = 20000
local y = setmetatable({[1] = {}}, {__mode = "kv"})
local B = 0
while y[1] do
  if B >= LIMIT2 then break end
  local a = B..B..B..B
  B = B + 1
end
print("alloc", y[1] == nil and "nil" or "alive")
