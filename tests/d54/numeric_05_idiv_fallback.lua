--! modes: B,R
-- '//' on operands the int64 helper declines (cdata, strings, tables with and
-- without __idiv): the VM calls lj_i64_arith first and only then falls back to
-- lj_meta_arith. On arm64 that fallback re-derived the operand slot and the
-- opcode from registers a C call may clobber (x16/x17): under an instrumented
-- build the metamethod/error path then read a garbage TValue (SEGV).
local F = require("ffi")
local function try(f, ...)
  local ok, r = pcall(f, ...)
  return "ok=" .. tostring(ok) .. " r=" .. tostring(r)
end
local function show(label, s)
  -- strip the chunk prefix so direct and dump/reload runs print the same
  print(label .. " | " .. (s:gsub("^ok=false r=.-:%d+: ", "ok=false r=")))
end

local i7, i3 = F.new("int64_t", 7), F.new("int64_t", 3)
show("cdata//cdata", try(function() return i7 // i3 end))
show("cdata//num", try(function() return i7 // 3 end))
show("num//cdata", try(function() return 7 // i3 end))
show("cdata//str", try(function() return i7 // "3" end))

show("str//num", try(function() return "7" // 2 end))
show("num//str", try(function() return 7 // "2" end))
show("str//str", try(function() return "7" // "2" end))
show("str//float", try(function() return "7" // 2.0 end))

local mt = {__idiv = function(a, b) return "mm(" .. tostring(type(a)) .. "," .. tostring(type(b)) .. ")" end}
local t = setmetatable({}, mt)
show("mt//num", try(function() return t // 2 end))
show("num//mt", try(function() return 2 // t end))
show("mt//cdata", try(function() return t // i3 end))
show("tab//num", try(function() return {} // 2 end))
show("num//tab", try(function() return 2 // {} end))
show("nil//num", try(function() return nil // 2 end))

-- The same operands under a hot loop (the JIT arm records or aborts here).
local acc, errs = 0, 0
for i = 1, 200 do
  local ok, r = pcall(function() return "9" // 2 end)
  if ok then acc = acc + r else errs = errs + 1 end
  ok, r = pcall(function() return t // i end)
  if ok and r:sub(1, 2) == "mm" then acc = acc + 1 else errs = errs + 1 end
  ok, r = pcall(function() return i7 // i3 end)
  if ok then errs = errs + 1 else acc = acc + 1 end
end
print("loop | " .. acc .. " " .. errs)

-- Register-only operands of the other 5.4 int64 helper paths stay intact.
local big = 1 << 62
print("i64 | " .. tostring(big + big) .. " " .. tostring(big * 4) .. " " .. tostring(-big - big))
