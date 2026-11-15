--! §4.2 error-message function names across tail calls.
--! KNOWN BUG (P1.8b): LuaJIT reuses the caller's frame on a tail call, so the
--! code-based name resolves to the grandparent's call. PUC 5.4 still reports
--! the called library function's short name. Non-tail calls are correct.
local function p(label, f)
  local ok, a = pcall(f)
  print(label .. " | " .. tostring(ok) .. " | " .. tostring(a):gsub("^.-:%d+: ", ""))
end
-- Non-tail calls: correct in both implementations.
p("nontail rep", function() local x = string.rep(nil, 1) return x end)
p("nontail move", function() local x = table.move(nil, 1, 1, 1) return x end)
-- Tail calls: LuaJIT reports the outer function name instead.
p("tail rep", function() return string.rep(nil, 1) end)
p("tail move", function() return table.move(nil, 1, 1, 1) end)
p("tail tonumber", function() return tonumber("1", 1) end)
-- Called through pcall (C caller): both use the loaded-module search.
p("pcall rep", function() return pcall(string.rep, nil, 1) end)
p("pcall move", function() return pcall(table.move, nil, 1, 1, 1) end)
