--! modes: A,B
-- A string argument may be any number: PUC 5.4.9 luaL_checklstring converts
-- it with lua_tolstring (lobject.c tostringbuff), integers outside int32
-- included. Here an integer in [2^31, 2^32) or outside the 47-bit inline
-- range is a boxed value, which the string argument check must convert like
-- any other number.

local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end
local function try(name, f, ...)
  local r = table.pack(pcall(f, ...))
  for i = 2, r.n do r[i] = tostring(r[i]) end
  print(name, r[1], strip(table.concat(r, " ", 2, r.n)))
end

local nums = {2147483647, 2147483648, 4294967295, 4294967296, 1 << 46,
              (1 << 46) - 1, 1 << 47, 1 << 62, math.maxinteger,
              math.mininteger, -2147483649, -(1 << 46), -(1 << 47), 2.5}
for _, v in ipairs(nums) do
  try("len " .. tostring(v), string.len, v)
  try("upper " .. tostring(v), string.upper, v)
  try("lower " .. tostring(v), string.lower, v)
  try("reverse " .. tostring(v), string.reverse, v)
  try("sub " .. tostring(v), string.sub, v, 2, 4)
  try("rep " .. tostring(v), string.rep, v, 2, v)
  try("byte " .. tostring(v), string.byte, v, -1)
  try("find " .. tostring(v), string.find, v, "4")
  try("match " .. tostring(v), string.match, v, "%d+")
  try("gsub " .. tostring(v), string.gsub, v, "%d", "x")
  try("gmatch " .. tostring(v), function(s) local t = {} for d in string.gmatch(s, "%d") do t[#t+1] = d end return #t end, v)
  try("format s " .. tostring(v), string.format, "%s|%5.3s", v, v)
  try("pack z " .. tostring(v), function(s) return #string.pack("z", s) end, v)
  try("concat sep " .. tostring(v), table.concat, {1, 2, 3}, v)
  try("load " .. tostring(v), function(s) return (load(s)) end, v)
  try("method " .. tostring(v), function(s) return ("%d"):rep(1, s) end, v)
end

-- The same calls in a hot loop (compiled under the JIT).
local function hot(v)
  local n = 0
  for k = 1, 300 do
    n = n + #string.upper(v) + string.len(v) + #string.sub(v, 1, 3)
      + #string.rep(v, 2) + (string.byte(v, 1))
  end
  return n
end
for _, v in ipairs{2147483648, 1 << 62, math.mininteger, 12} do
  print("hot", v, hot(v))
end
