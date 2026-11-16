--! Deliberate divergence from stock LuaJIT (Markus, 2026-11-16): identifiers
--! are strict Lua 5.4 (ASCII letters/digits/underscore only). Stock LuaJIT
--! accepted bytes 128-255 as identifier characters; PUC 5.4 rejects them.
--! This test is differential vs PUC: same syntax error, normalized.
local function norm(err)
  err = err:gsub("^.-:%d+: ", "")
  err = err:gsub("near .*$", "near TOKEN")
  err = err:gsub("^.* near TOKEN$", "SYNTAX near TOKEN")
  return err
end
local function check(name, s)
  local f, err = load(s, "")
  print(name, f == nil, f == nil and norm(err) or "LOADED")
end
-- ASCII identifiers and _ are fine in both.
print("ascii", load("abc = 1") ~= nil, load("_x9 = 1") ~= nil)
check("utf8-1", string.char(0xC3, 0xA9) .. " = 1")
check("utf8-2", "abc" .. string.char(0xE2, 0x82, 0xAC) .. " = 1")
check("byte-255", string.char(255) .. " = 1")
-- A byte >=128 after a valid name start is also rejected.
check("tail", "abc" .. string.char(0xB0) .. " = 1")
