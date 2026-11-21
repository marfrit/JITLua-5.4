--! §2.6 table.unpack (and string.byte, utf8.codepoint) may return as many
--! values as the stack can hold: PUC lua_checkstack grows up to LUAI_MAXSTACK
--! (1000000 slots). This tree capped lua_checkstack at LUAI_MAXCSTACK (8000)
--! and string.byte at 8000 results, so table.unpack({}, 1, 10000) failed
--! with "too many results to unpack". The stack limit here is LJ_STACK_MAX
--! (65500 slots, the stack-depth row in docs/DIFFERENCES.md), so a request
--! beyond that still fails; PUC fails only above 1000000. A vararg call
--! copies its arguments once more, so the 50000 values go straight to
--! select (fits here) and not through a vararg function (twice the slots).
--! Printed: result counts and the errors for requests far beyond both limits.
local function count(...) return select("#", ...) end
print(count(table.unpack({}, 1, 10000)))
print(select("#", table.unpack({}, 1, 50000)))
local t = {}
for i = 1, 20000 do t[i] = i end
local a = {table.unpack(t)}
print(#a, a[1], a[20000])
local s = string.rep("a", 20000)
print(select("#", string.byte(s, 1, -1)))
print(select("#", utf8.codepoint(s, 1, -1)))
print(pcall(table.unpack, {}, 1, 1e7))
print(pcall(table.unpack, {}, math.mininteger, math.maxinteger))
local n
for _ = 1, 100 do n = count(table.unpack(t, 1, 9000)) end
print("hot", n)
