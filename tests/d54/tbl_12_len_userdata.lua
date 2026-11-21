--! §3.4.7 lua_len of a userdata without __len is an error (PUC lapi.c
--! lua_len -> luaV_objlen: "attempt to get length of a FILE* value", the
--! name from __name). This tree returned the userdata's block size, so
--! table.unpack(io.stdout) gave about two dozen nils and table.concat,
--! table.insert/remove, table.move, table.sort and luaL_len saw a length.
--! Printed: the results or errors, also from a compiled loop.
local function p(label, f, ...)
  local r = table.pack(pcall(f, ...))
  local t = {}
  for i = 2, r.n do t[#t + 1] = (tostring(r[i]):gsub("^[^:]*:%d+: ", "")) end
  print(label, r[1], r.n - 1, table.concat(t, " / "))
end
local ud = io.stdout
p("unpack", table.unpack, ud)
p("unpack range", table.unpack, ud, 1, 2)
p("len op", function() return #ud end)
p("len stderr", function() return #io.stderr end)
p("concat", table.concat, ud)
p("insert", table.insert, ud, 1)
p("remove", table.remove, ud)
p("sort", table.sort, ud)
p("move", function() return type(table.move(ud, 1, 2, 1, {})) end)
p("box int", table.unpack, 1 << 60)
p("utf8 len", utf8.len, "abc")
local n = 0
for _ = 1, 100 do if not pcall(table.unpack, ud) then n = n + 1 end end
print("hot", n)
