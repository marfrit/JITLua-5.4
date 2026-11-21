--! §6.4.2/§4.2: string.format("%p") in 5.4.9 formats values without a
--! pointer as the string "(null)" and applies the width and the '-' flag to
--! it (lstrlib.c: the specifier is rewritten to 's'). LuaJIT printed "NULL"
--! and ignored width and flags for %p entirely. The pointer of a real object
--! is still printed as 0x..., under the same width rule. %p's invalid
--! modifiers (precision, flags) are covered in fmt_03 with the other specs.
local function f(fmt, ...) return (pcall(string.format, fmt, ...)) end
local function p(name, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local x = select(i, ...)
    t[i] = tostring(x) .. ":" .. type(x)
  end
  print(name .. " | " .. table.concat(t, " | "))
end

-- values without a pointer
for _, v in ipairs{4, 1.5, true, false} do
  print(string.format("[%p]", v))
end
print(string.format("[%p]", nil))
p("no pointer", f("%p", 4), f("%p", true), f("%p", nil))
-- width, left flag and length
print(#string.format("%10p", false), #string.format("%-12p", 1.5),
      #string.format("%-10p", nil))
print(string.format("[%10p]", false), string.format("[%-12p]", 1.5))
-- a real object under a width (the address itself is normalized)
print(#string.format("%90p", {}), #string.format("%-60p", {}))
local t = {}
print(string.format("%p", t) == string.format("%p", t))
print(string.format("%p", t) == string.format("%p", {}))
print(string.format("%20p", t):sub(1, 2), #string.format("%20p", t))
print("ok")
