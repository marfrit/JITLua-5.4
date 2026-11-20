--! GC string-table sweep under heavy churn: intern-table growth, shrink and
--! rehash, plus the reserved-word (never-collected) path.  A wrong free or a
--! broken hash chain in gc_sweepstr loses a live string, duplicates it, or
--! drops a fixed string; under ASan/UBSan it aborts, and the checks below go
--! red.  Output is byte-identical under PUC 5.4.9 and JITLua-5.4.
--!
--! Deterministic on purpose: only Lua-level facts are printed (counts,
--! checksums, identity booleans), never table sizes or collectgarbage("count"),
--! which differ between the two implementations.

local N = 40000          -- well past LJ_MIN_STRTAB (256): forces several doublings

local function mk(i)
  return string.format("grow-%d-%d", i, i * 7 % 1009)
end

-- 1. Grow: intern N distinct short strings and keep every one of them.
local keep = {}
for i = 1, N do keep[i] = mk(i) end

-- 2. Churn: allocate and drop many temporaries between the kept strings so the
--    collector runs many incremental steps and several full cycles while the
--    table is large.  These strings are short (< LUAI_MAXSHORTLEN), so both
--    implementations intern them and rawequal is meaningful.
for round = 1, 8 do
  local tmp = {}
  for i = 1, 5000 do tmp[i] = string.format("tmp-%d-%d", round, i) end
  collectgarbage("step", 1)
  if round % 2 == 0 then collectgarbage("collect") end
  tmp = nil
end

-- 3. Shrink: drop 7/8 of the kept strings (keep every 8th), then run enough
--    full cycles for the interning table to halve repeatedly (the shrink runs
--    once per cycle, and only when the live count is below a quarter of the
--    table size).
for i = 2, N do if i % 8 ~= 1 then keep[i] = nil end end
for _ = 1, 6 do collectgarbage("collect") end

-- 4. Verify the survivors: still equal to a freshly built copy (not lost from
--    the table) and still the *same* interned object (chain not truncated).
local n, h = 0, 0
for i = 1, N, 8 do
  local s = keep[i]
  if s ~= nil then
    n = n + 1
    h = (h + #s * 31 + i) % 1000003
    local again = mk(i)
    assert(s == again, "interned string lost from the table")
    assert(rawequal(s, again), "interning chain broken (duplicate created)")
  end
end
print("survivors", n, h)

-- 5. Reserved words are fixed strings: they are never freed, and they are the
--    ones the lexer keeps.  Re-parse and run a chunk that uses most keywords
--    after several full cycles; a freed reserved word dangles here.
local src = [[
local s = 0
for i = 1, 3 do
  if i > 1 then s = s + i else s = s - 1 end
end
local t = {}
while #t < 2 do t[#t + 1] = true end
repeat s = s + 1 until s > 5
return s, #t
]]
for _ = 1, 5 do collectgarbage("collect") end
local f = assert(load(src))
local a, b = f()
print("keywords", a, b, type("and"), ("and"):upper())

-- 6. Identity after the shrink/rehash: equal short strings must still be one
--    object, and a table keyed by a survivor must still be found.
local key = keep[1]
local t = {[key] = 42}
for _ = 1, 3 do collectgarbage("collect") end
print("identity", rawequal(key, mk(1)), t[mk(1)], rawequal("rehash-" .. N, ("rehash-"):rep(1) .. N))
print("ok")
