--! §4.2 table-library metamethods. PUC 5.4.9 ltablib.c routes every table
--! access through lua_geti/lua_seti/luaL_len behind checktab(TAB_R/TAB_W/TAB_L),
--! so table.insert/remove/concat/sort/unpack/move honour __index/__newindex/__len
--! and accept table-like values (a non-table whose metatable carries the needed
--! metamethods). Plain tables without those metamethods must keep their current
--! observable behaviour (the fast path).
--!
--! Float-valued integer arguments (pos/i/e/f = 2.5 etc.) are asserted to RAISE,
--! not to print a message: the exact "number has no integer representation" text
--! is owned by the libparity session (src/lj_api.c luaL_checkinteger).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function err(f, ...)
  local ok, e = pcall(f, ...)
  return (ok and "ok" or "ERR: " .. tostring(e))
end
local function res(f, ...)
  local ok, r = pcall(f, ...)
  return (ok and tostring(r) or "ERR: " .. tostring(r))
end
local function pcall1(f, ...)
  local ok = pcall(f, ...)
  return ok
end

-- 1. Plain tables (regression baseline for the fast path).
do
  local t = { 1, 2, 3 }
  p("plain ins end", err(table.insert, t, 4), table.concat(t, ","))
  p("plain ins pos", err(table.insert, t, 2, 9), table.concat(t, ","))
  p("plain rmv", table.remove(t, 2), table.concat(t, ","))
  p("plain cat", table.concat({ 1, 2, 3 }, "-"), table.concat({ 1, 2, 3 }, "-", 2, 2))
  p("plain unp", table.unpack({ 1, 2, 3 }), table.unpack({ 1, 2, 3 }, 2, 3))
  p("plain sort", (function() local t = { 3, 1, 2 } table.sort(t) return table.concat(t, ",") end)())
  p("plain mv", table.concat(table.move({ 1, 2, 3, 4, 5 }, 2, 4, 1), ","))
  p("plain mv dest", table.concat(table.move({ 1, 2, 3 }, 1, 3, 1, {}), ","))
  p("plain pack", (function() local q = table.pack(1, nil, 3) return q.n, q[1], q[3] end)())
end

-- 2. Proxy with all three metamethods, backed by a real table.
do
  local t = {}
  local proxy = setmetatable({}, {
    __len = function() return #t end,
    __index = t,
    __newindex = t,
  })
  for i = 1, 10 do table.insert(proxy, 1, i) end
  p("proxy len", #proxy, #t)
  p("proxy backing", table.concat(t, ","))
  p("proxy sort", err(table.sort, proxy), t[1], t[5], t[10])
  p("proxy cat", res(table.concat, proxy, ","))
  local rm = {}
  for i = 1, 8 do rm[i] = table.remove(proxy, 1) end
  p("proxy rmv", table.concat(rm, ","), #proxy, #t)
  local mvt = {}
  local mv = setmetatable({}, {
    __len = function() return #mvt end,
    __index = mvt,
    __newindex = mvt,
  })
  for i = 1, 10 do mvt[i] = i end
  p("proxy mv", err(table.move, mv, 1, 3, 9, mv), mvt[9], mvt[10], mvt[11])
end

-- 3. Only __newindex (rawset backing so reads still work).
do
  local count = 0
  local t = setmetatable({}, {
    __newindex = function(tb, k, v) count = count + 1; rawset(tb, k, v) end })
  for i = 1, 10 do table.insert(t, 1, i) end
  p("newidx count", count, #t, t[1], t[10])
  p("newidx sort", err(table.sort, t), t[1], t[5])
  p("newidx cat", res(table.concat, t, ";"))
  p("newidx rmv", table.remove(t, 1), #t, t[1])
  p("newidx unp", table.unpack(t, 1, 3))
end

-- 4. __index + __len, no __newindex.
do
  local t = setmetatable({}, {
    __index = function(_, k) return k + 1 end,
    __len = function(_) return 5 end })
  p("idxlen cat", res(table.concat, t, ";"))
  p("idxlen unp", table.unpack(t, 1, 3))
  p("idxlen sort", err(table.sort, t))
  p("idxlen ins", err(table.insert, t, 42), #t, t[6])
  p("idxlen rmv", table.remove(t), #t)
end

-- 5. Only __len.
do
  local t = setmetatable({}, { __len = function() return 3 end })
  p("lenonly len", #t)
  p("lenonly ins", err(table.insert, t, 42), #t, t[4])
  p("lenonly sort", err(table.sort, t))
  p("lenonly cat", res(table.concat, t, ";"))
  p("lenonly rmv", table.remove(t), t[1], t[2], t[3])
  p("lenonly unp", table.unpack(t, 1, 2))
end

-- 6. Overflow: __len = maxinteger (PUC wraps e to mininteger).
do
  local t = setmetatable({}, { __len = function() return math.maxinteger end })
  p("ovf ins", err(table.insert, t, 20), next(t))
end

-- 7. Table-like values (non-table whose metatable carries metamethods).
--    Hermetic: a thread and a string (both have metatables in 5.4).
do
  local th = coroutine.create(function() end)
  p("tl thread sort", err(table.sort, th))
  p("tl thread mv src", err(table.move, th, 1, 1, 1, {}))
  p("tl str cat", err(table.concat, "abc"))
  p("tl str ins", err(table.insert, "abc", "x"))
end

-- 8. Non-table arguments without the required metamethods: uniform error.
do
  p("nt ins nil",  err(table.insert, nil))
  p("nt ins num",  err(table.insert, 42))
  p("nt ins str",  err(table.insert, "s"))
  p("nt ins bool", err(table.insert, true))
  p("nt rmv nil",  err(table.remove, nil))
  p("nt rmv num",  err(table.remove, 42))
  p("nt cat nil",  err(table.concat, nil))
  p("nt cat num",  err(table.concat, 42))
  p("nt sort nil", err(table.sort, nil))
  p("nt sort bool",err(table.sort, true))
  p("nt mv nil",   err(table.move, nil, 1, 1, 1))
  p("nt mv dst num",err(table.move, {}, 1, 1, 1, 42))
end

-- 9. concat float elements (Lua 5.4 coercion rules).
do
  for _, t in ipairs { { 1.5 }, { 0.5, 2.5 }, { 1.0, 2 }, { "a", 1 } } do
    local ok, r = pcall(table.concat, t, ",")
    p("catfl", ok and ("v=" .. r) or ("ERR: " .. tostring(r)))
  end
end

-- 10. Argument errors on real tables. Float args: assert RAISE only (no text).
do
  p("ins no value", err(table.insert, {}))
  p("ins 4 args", err(table.insert, { 1 }, 1, 2, 3))
  p("ins pos 0", err(table.insert, { 1, 2, 3 }, 0, 9))
  p("ins pos too big", err(table.insert, { 1, 2, 3 }, 5, 9))
  p("ins pos str", err(table.insert, { 1, 2, 3 }, "x", 9))
  p("ins pos float", pcall1(table.insert, { 1, 2, 3 }, 2.5, 9))
  p("rmv pos 0", err(table.remove, { 1, 2, 3 }, 0))
  p("rmv pos too big", err(table.remove, { 1, 2, 3 }, 5))
  p("rmv pos str", err(table.remove, { 1, 2, 3 }, "x"))
  p("rmv pos float", pcall1(table.remove, { 1, 2, 3 }, 2.5))
  p("cat nil idx", err(table.concat, { 1, nil, 3 }))
  p("cat table idx", err(table.concat, { 1, {} }))
  p("cat i>last", (function() local r, o = pcall(table.concat, { "a", "b" }, "-", 3, 1)
    return (r and ("v=" .. tostring(o)) or "ERR: " .. tostring(o)) end)())
  p("rmv pos size+1", table.remove({ 1, 2, 3 }, 4), table.concat({ 1, 2, 3 }, ","))
  p("rmv pos size+2", err(table.remove, { 1, 2, 3 }, 5))
  p("rmv empty pos0", table.remove({}, 0))
  p("rmv empty pos-1", err(table.remove, {}, -1))
  p("cat nonint", pcall1(table.concat, { 1, 2 }, "-", 1.5))
  p("cat bad end", pcall1(table.concat, { 1, 2 }, "-", 1, 2.5))
  p("sort cmp", err(table.sort, { 1, "a" }))
  p("sort invalid ord", err(table.sort, { 1, 2 }, function() return true end))
  p("unp nonint", pcall1(table.unpack, { 1 }, 1, 2.5))
  p("mv bad f", err(table.move, { 1 }, "x", 1, 1))
  p("mv f float", pcall1(table.move, { 1 }, 1.5, 2, 1))
end

-- 11. __len returning a non-integer.
do
  local t = setmetatable({}, { __len = function() return 2.5 end })
  p("len float ins", err(table.insert, t, 1))
  p("len float rmv", err(table.remove, t))
  p("len float cat", err(table.concat, t, ";"))
  p("len float sort", err(table.sort, t))
  p("len float unp", err(table.unpack, t))
end

-- 12. pack: copies values, no metatable involvement expected.
do
  local proxy = setmetatable({}, {
    __len = function() return 3 end,
    __index = { "a", "b", "c" },
    __newindex = function() end,
  })
  local q1 = table.pack(proxy, 1, "x")
  p("pack proxy args", q1.n, q1[1] == proxy, q1[2], q1[3])
  p("pack plain", (function() local q2 = table.pack(1, 2) return q2.n, q2[1], q2[2] end)())
  p("pack empty", table.pack().n)
end

-- 13. Hot loops (compile under -jon): plain and proxy, all functions. These keep
--     the recorder on the table.* C functions so a missing metatable guard shows
--     up as a JIT-vs-interpreter divergence in mode B.
--     Loop sizes: >= ~4x the hotloop threshold (56, src/lj_jit.h) so the chunks
--     compile; the proxy loops (each iteration = several metamethod calls) are
--     kept small because the sanitizer build pays a heavy per-call cost there
--     (the 120 s harness timeout is per arm).
do
  local t = {}
  for i = 1, 5000 do table.insert(t, i) end
  p("hot plain ins", #t, t[1], t[5000])
  local c
  for i = 1, 5000 do c = table.concat({ "a", "b" }, "-") end
  p("hot plain cat", c)
  local u
  for i = 1, 5000 do u = select(3, table.unpack({ 1, 2, 3, 4 })) end
  p("hot plain unp", u)
  local s = { 4, 2, 5, 1, 3 }
  for i = 1, 5000 do table.sort({ 4, 2, 5, 1, 3 }) end
  p("hot plain sort", s[1])
end
do
  local bt = {}
  local proxy = setmetatable({}, {
    __len = function() return #bt end,
    __index = bt,
    __newindex = bt,
  })
  for i = 1, 250 do table.insert(proxy, i) end
  p("hot proxy ins", #proxy, bt[1], bt[250])
  local c
  for i = 1, 125 do c = table.concat(proxy, ",") end
  p("hot proxy cat len", #c)
  local r
  for i = 1, 125 do r = table.remove(proxy, 1) end
  p("hot proxy rmv last", r)
end
print("done")
