---! §6.6 table.sort and `<` on 5.4 integers in all encodings (int32, widened
---! 47-bit, boxed) and mixed with floats: default comparator (lua_lessthan),
---! Lua comparators (ISLT/ISGE/ISLE/ISGT on boxes and widened values), and
---! the sorted order against PUC. Mode A vs PUC, mode B JIT vs interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end
local w, b = 1 << 40, 1 << 60
-- Default comparator: widened keys share low words (bug magnet), boxes, mixes.
local t = {}
for i = 1, 200 do t[#t+1] = (w * (i % 7)) + 3 end           -- widened, equal low words
for i = 1, 200 do t[#t+1] = b + i * 512 end                 -- boxed
for i = 1, 200 do t[#t+1] = -(w * (i % 5)) - i end           -- negative widened
for i = 1, 50 do t[#t+1] = i; t[#t+1] = i + 0.5; t[#t+1] = -i end  -- int32 and floats
t[#t+1] = math.mininteger; t[#t+1] = math.maxinteger; t[#t+1] = 2^62; t[#t+1] = -2^62
table.sort(t)
local ok = true
for i = 2, #t do if not (t[i-1] <= t[i]) then ok = false end end
local hash = 0
for i = 1, #t do hash = (hash * 31 + (math.type(t[i]) == "integer" and t[i] or math.floor(t[i] * 2) // 2^20)) & 0xffffffffffff end
p("default", #t, ok, hash, t[1], t[2], t[#t-1], t[#t])
-- Lua comparators (hot: run through the VM's compare fast paths).
local u = {}
for i = 1, #t do u[i] = t[#t + 1 - i] end
table.sort(u, function(x, y) return x < y end)
local same = true
for i = 1, #t do if u[i] ~= t[i] then same = false end end
table.sort(u, function(x, y) return x > y end)
p("comparators", same, u[1], u[#u])
-- All four orderings on boxes, widened, int32 and mixed pairs, in a loop.
local lt, le, gt, ge = 0, 0, 0, 0
local pairs_ = {{b + 1, b + 2}, {b + 2, b + 1}, {w + 1, w + 2}, {w + 2, w + 1}, {b, w}, {w, b},
  {-(b + 1), -(w + 1)}, {3, w}, {w, 3}, {b, 2^62}, {2^62, b + 1}, {w, w + 0.5}, {b + 1, b + 1}, {w, w}}
for rep = 1, 200 do
  for _, pr in ipairs(pairs_) do
    local x, y = pr[1], pr[2]
    if x < y then lt = lt + 1 end
    if x <= y then le = le + 1 end
    if x > y then gt = gt + 1 end
    if x >= y then ge = ge + 1 end
  end
end
p("orderings", lt, le, gt, ge)
p("errors", pcall(function() return b < "x" end), pcall(function() return {} < b end),
  pcall(function() return 2^63 & 1 end), pcall(function() return 2^63 | w end), pcall(function() return -2^63 & 1 end))
