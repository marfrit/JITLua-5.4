--! §2.7 io: a new file handle takes its metatable from registry["FILE*"]
--! (PUC liolib.c newprefile, luaL_setmetatable). With the entry removed PUC
--! creates the handle without a metatable; this tree read the entry as a
--! table without a check and crashed (bus error / segfault). Printed: the
--! handle's metatable, io.type and the results of using it; the type name
--! in an operand error is the metatable's __name ("FILE*" for the standard
--! one, PUC luaT_objtypename), not a name fixed by the handle's kind.
local reg = debug.getregistry()
local saved = reg["FILE*"]
local mt = getmetatable(io.stdout)
print("same metatable", mt == saved)
reg["FILE*"] = nil
local f = io.open("/dev/null")
print("no entry", getmetatable(f), pcall(function() return f:read() end))
reg["FILE*"] = saved
local g = io.open("/dev/null")
print("restored", getmetatable(g) == saved, io.type(g), g:read("a"))
g:close()
local other = {__name = "other"}
reg["FILE*"] = other
local h = io.open("/dev/null")
print("other table", getmetatable(h) == other, tostring(h):sub(1, 6))
print("other name", pcall(function() return h + 1 end))
reg["FILE*"] = saved
print("std name", pcall(function() return io.stdout + 1 end))
