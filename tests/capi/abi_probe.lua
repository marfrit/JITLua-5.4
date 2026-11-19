-- Driver for tests/capi/abi_probe.c built against JITLua's headers.
-- require() opens the module, which runs luaL_checkversion(); the upvalue and
-- registry calls below prove that this fork's pseudo-indices are in use.
local p = require "abi_probe"
assert(p.upval("ignored") == "upvalue-ok", "lua_upvalueindex(1) must read the closure upvalue")
assert(p.registry() == "registry-ok", "LUA_REGISTRYINDEX must be this fork's registry")
print("abi_probe: OK JITLua-built module")
