--! §5 load/loadfile mode rejection: PUC echoes the requested mode string
--! ("attempt to load a text chunk (mode is 'bx')"), not the actual chunk kind.
--! Differential against PUC 5.4.9.
local function norm(e)
  local s = tostring(e)
  s = s:gsub("^.-:%d+: ", "")
  return s
end
local function q(label, ...)
  local t = { pcall(load, ...) }
  local v = t[1] and (type(t[2]) == "function" and "function" or tostring(t[2]))
  print(label .. " | ok=" .. tostring(t[1]) .. " | " ..
	(t[1] and v or norm(t[2])))
end
q("text mode bx", "return 1", "c", "bx")
q("text mode q", "return 1", "c", "q")
q("text mode empty", "return 1", "c", "")
q("binary mode t", string.dump(function() return 1 end), "c", "t")
q("binary mode tx", string.dump(function() return 1 end), "c", "tx")
q("text mode t", "return 1", "c", "t")
q("text mode bt", "return 1", "c", "bt")
q("text mode tb", "return 1", "c", "tb")

local name = os.tmpname()
local f = io.open(name, "w"); f:write("return 1\n"); f:close()
local function lf(label, mode)
  local ok, a = pcall(loadfile, name, mode)
  print(label .. " | ok=" .. tostring(ok) .. " | " ..
	(ok and (type(a) == "function" and "function" or tostring(a))
	 or norm(a)))
end
lf("loadfile mode b", "b")
lf("loadfile mode q", "q")
lf("loadfile mode empty", "")
lf("loadfile mode t", "t")
os.remove(name)
