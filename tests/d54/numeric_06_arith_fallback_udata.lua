--! modes: B,R
-- Arithmetic metamethod fallbacks reached AFTER a C call to lj_i64_arith
-- (the helper declined). On arm64 the fallback entries re-derived the operand
-- slot and opcode from x16/x17, which any C call may clobber; numeric_05
-- covers only the VV entry via '//'. VN/NV are reached with a non-box
-- userdata operand (upper tag bits 0xfff9, so checkintw hands it to the
-- helper), VV also with a widened int and a string/table operand.
local big = 1 << 40
local f = io.stdout
local mt = {}
for _, k in ipairs({"add","sub","mul","div","mod","pow","idiv"}) do
  mt["__" .. k] = function(a, b) return k .. "(" .. type(a) .. "," .. type(b) .. ")" end
end
local t = setmetatable({}, mt)
local function try(label, fn)
  local ok, r = pcall(fn)
  print(label, ok, (tostring(r):gsub("^.-:%d+: ", "")))
end
for round = 1, 2 do  -- second round runs hot under -jon
  for _ = 1, 100 do pcall(function() return f + 1 end); pcall(function() return 1 + f end) end
  do  -- vn
    try("vn add", function() return f + 1 end)
    try("vn sub", function() return f - 1 end)
    try("vn mul", function() return f * 2 end)
    try("vn div", function() return f / 2 end)
    try("vn pow", function() return f ^ 2 end)
    try("vn mod", function() return f % 2 end)
  end
  do  -- nv
    try("nv add", function() return 1 + f end)
    try("nv sub", function() return 1 - f end)
    try("nv mul", function() return 2 * f end)
    try("nv div", function() return 2 / f end)
    try("nv pow", function() return 2 ^ f end)
    try("nv mod", function() return 2 % f end)
  end
  do  -- vv
    try("vv add str", function() return big + "3" end)
    try("vv sub str", function() return big - "1" end)
    try("vv mul str", function() return big * "2" end)
    try("vv div str", function() return big / "2" end)
    try("vv pow str", function() return big ^ "1" end)
    try("vv mod str", function() return big % "7" end)
    try("vv idiv str", function() return big // "3" end)
    try("vv add mt", function() return big + t end)
    try("vv idiv mt", function() return big // t end)
    try("vv add ud", function() return f + f end)
    try("vv idiv ud", function() return f // f end)
  end
end
