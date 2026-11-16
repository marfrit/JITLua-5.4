---! §3.4.1/§6.6 integer table keys: 5.4 normalises integral float keys to
---! integers (t[2^40] is t[1<<40], next() hands back integers) for keys in
---! all three encodings (int32, widened 47-bit, boxed); next/pairs, rawget/
---! rawset, weak tables, template tables and the JIT's HREF/HREFK/NEWREF with
---! int32 and int64 keys. Mode A compares with PUC, mode B JIT vs interpreter.
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end

-- Interpreter-level semantics (also run by the JIT, but not in loops).
local t = {}
t[1 << 40] = "w"; t[2^40] = "wf"
t[1 << 60] = "b"; t[2^60] = "bf"
t[-(1 << 40)] = "nw"; t[math.mininteger] = "min"; t[2^63] = "f63"
t[100000] = "h"; t[2^53] = "f53"; t[1 << 53] = "i53"; t[-7] = "neg"
p("get", t[1<<40], t[2^40], t[1<<60], t[2^60], t[-(1<<40)], t[math.mininteger],
  t[2^63], t[100000], t[1<<53], t[-7], t[-7.0])
p("rawget", rawget(t, 1<<40), rawget(t, 2^60), rawget(t, -(1<<40)), rawget(t, 100000.0))
local keys = {}
for k, v in pairs(t) do keys[#keys+1] = tostring(k) .. "/" .. math.type(k) .. "=" .. v end
table.sort(keys); p("pairs", table.concat(keys, " "))
local kt = {}
local k = next(t)
while k do kt[#kt+1] = math.type(k); k = next(t, k) end
table.sort(kt); p("next", table.concat(kt, ","))
-- next() takes the key as stored: a float key is not normalised (PUC findindex).
p("next-from", (pcall(next, t, 1<<40)), (pcall(next, t, 1<<60)), (pcall(next, t, 100000)),
  (pcall(next, t, 2^40)), (pcall(next, t, 1<<59)), (pcall(next, t, 100000.0)), (pcall(next, t, 2^63)))

-- Template tables with int64 constant keys and values (mode R: dump/reload).
local tmpl = {[1099511627776] = "tw", [1152921504606846976] = "tb", [100000] = "th",
  1099511627776, 1152921504606846976, [-1099511627776] = "tnw"}
p("template", tmpl[1<<40], tmpl[1<<60], tmpl[100000], tmpl[-(1<<40)], tmpl[1], tmpl[2])

-- Metamethods receive the key as given (float stays float).
local m = setmetatable({}, {__index = function(_, k) return math.type(k) end,
  __newindex = function(tt, k, v) rawset(tt, k, math.type(k) .. v) end})
m[1 << 50] = "x"; m[2^51] = "y"
p("meta", m[1<<41], m[2^41], m[7.0], rawget(m, 1<<50), rawget(m, 2^50), rawget(m, 1<<51))

-- Hot loops: sparse int32 keys in the hash part (HREF/NEWREF with int keys).
local h, hs = {}, 0
for i = 1, 2000 do h[i * 100000] = i end
for i = 1, 2000 do hs = hs + h[i * 100000] end
for i = 1, 2000, 2 do h[i * 100000] = nil end
local hc = 0
for _ in pairs(h) do hc = hc + 1 end
p("sparse-int32", hs, hc, h[200000], h[300000], h[100000.0])
local neg, ns = {}, 0
for i = 1, 1000 do neg[-i] = i end
for i = 1, 1000 do ns = ns + neg[-i] + neg[-i + 0.0] end
p("negative", ns, neg[-500], neg[-500.0])

-- Constant hash keys (HREFK with int32, widened and boxed constants).
local c, cs = {[100000] = 1, [1 << 40] = 2, [1 << 60] = 3}, 0
for i = 1, 1000 do
  c[100000] = c[100000] + 1; c[1 << 40] = c[1 << 40] + 2; c[1 << 60] = c[1 << 60] + 3
  cs = cs + c[100000] + c[1 << 40] + c[1 << 60]
end
p("const", cs, c[100000], c[2^40], c[2^60])

-- Widened and boxed variable keys: stores (NEWREF int64), loads, deletes.
local w, b, ws, bs = {}, {}, 0, 0
-- (boxed keys step by 512: 2^60 + i*512 is exact as a float, 2^60 + i is not)
for i = 1, 2000 do w[(1 << 40) + i] = i; b[(1 << 60) + i * 512] = -i end
for i = 1, 2000 do ws = ws + w[(1 << 40) + i]; bs = bs + b[(1 << 60) + i * 512] end
for i = 1, 2000 do ws = ws + w[2^40 + i]; bs = bs + b[2^60 + i * 512] end  -- float keys
for i = 1, 2000, 3 do w[(1 << 40) + i] = nil; b[2^60 + i * 512] = nil end
local wc, bc = 0, 0
for _ in pairs(w) do wc = wc + 1 end
for _ in pairs(b) do bc = bc + 1 end
p("var-int64", ws, bs, wc, bc, w[(1<<40)+2], b[(1<<60)+1024], w[(1<<40)+1], b[(1<<60)+512])

-- A key that crosses encodings inside one loop (exits and re-records).
local x, xs = {}, 0
for i = 1, 3000 do
  local r = i % 4
  local key = (r == 0) and i or (r == 1) and (1 << 40) + i or (r == 2) and (1 << 60) + i or i + 0.5
  x[key] = i
  xs = xs + x[key]
end
local xc = 0
for _ in pairs(x) do xc = xc + 1 end
p("mixed", xs, xc, x[4], x[(1<<40)+5], x[(1<<60)+6], x[7.5], x[8 + 0.0])

-- Integral and non-integral float keys in loops (CHECK / non-integral guards).
local f, fs = {}, 0
for i = 1, 1000 do f[i + 0.0] = i; f[i + 0.5] = -i end
for i = 1, 1000 do fs = fs + f[i] + f[i + 0.5] + f[i + 0.0] end
local fi, ff = 0, 0
for k2 in pairs(f) do if math.type(k2) == "integer" then fi = fi + 1 else ff = ff + 1 end end
p("float-keys", fs, fi, ff)
local g, gs = {}, 0
for i = 1, 1000 do g[2^40 + i] = i end  -- integral floats outside int32
for i = 1, 1000 do gs = gs + g[(1 << 40) + i] end
local gi = 0
for k2 in pairs(g) do if math.type(k2) == "integer" then gi = gi + 1 end end
p("float-i64-keys", gs, gi, g[2^40 + 1], g[(1<<40) + 1000])

-- pairs/next over int64 keys in a loop, summing keys and values.
local q = {}
for i = 1, 64 do q[(1 << 33) * i] = i; q[(1 << 59) + i] = -i end
local qk, qv = 0, 0
for rep = 1, 100 do for k2, v in pairs(q) do qk = qk + k2; qv = qv + v end end
p("pairs-i64", qk, qv)

-- rawget/rawset with int64 keys in loops.
local r, rs = {}, 0
for i = 1, 1000 do rawset(r, (1 << 44) + i, i); rawset(r, (1 << 61) + i * 1024, i) end
for i = 1, 1000 do rs = rs + rawget(r, (1 << 44) + i) + rawget(r, 2^61 + i * 1024) end
p("raw", rs)

-- Weak tables: integers are values, never collected as keys or values.
local wk = setmetatable({}, {__mode = "k"})
local wv = setmetatable({}, {__mode = "v"})
local wkv = setmetatable({}, {__mode = "kv"})
for i = 1, 100 do
  wk[(1 << 60) + i] = i; wv[i] = (1 << 60) + i; wkv[(1 << 60) + i] = (1 << 61) + i
  wk[{}] = i; wv[-i] = {}
end
collectgarbage(); collectgarbage()
local nk, nv, nkv = 0, 0, 0
for _ in pairs(wk) do nk = nk + 1 end
for _ in pairs(wv) do nv = nv + 1 end
for _ in pairs(wkv) do nkv = nkv + 1 end
p("weak", nk, nv, nkv, wk[(1<<60)+5], wv[5], wkv[(1<<60)+5])

-- Many boxed keys with GC pressure (boxes used only as keys stay alive).
local big = {}
for i = 1, 20000 do big[(1 << 62) + i * 7] = i end
collectgarbage()
local bsum = 0
for i = 1, 20000 do bsum = bsum + big[(1 << 62) + i * 7] end
p("gc-keys", bsum)
