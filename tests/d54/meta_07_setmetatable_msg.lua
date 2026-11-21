--! §5 setmetatable/debug.setmetatable second argument: PUC names the target
--! type ("nil or table expected, got number" / "got string"). Differential
--! against PUC 5.4.9.
local function norm(e)
  local s = tostring(e)
  return s:gsub("^.-:%d+: ", "")
end
local function q(label, f, ...)
  local ok, a = pcall(f, ...)
  print(label .. " | ok=" .. tostring(ok) .. " | " ..
	(ok and tostring(a) or norm(a)))
end
q("setmetatable number", setmetatable, {}, 1)
q("setmetatable string", setmetatable, {}, "x")
q("setmetatable boolean", setmetatable, {}, true)
q("setmetatable nil", setmetatable, {}, nil)
q("setmetatable first bad", setmetatable, 1, {})
q("debug.setmetatable number", debug.setmetatable, {}, 1)
q("debug.setmetatable string", debug.setmetatable, {}, "x")
q("debug.setmetatable nil", debug.setmetatable, {}, nil)
