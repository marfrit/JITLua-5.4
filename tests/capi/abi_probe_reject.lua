-- Driver for tests/capi/abi_probe.c built against PUC 5.4.9's headers and
-- loaded by JITLua.  It must not load: opening it calls luaL_checkversion()
-- with PUC's numeric stamp, which JITLua now recognises as a different ABI.
local ok, err = pcall(require, "abi_probe")
assert(not ok, "a module built against PUC 5.4 headers must not load")
assert(type(err) == "string", "the rejection must be an error string")
assert(err:find("different Lua ABI", 1, true),
       "the rejection must name the ABI difference: " .. tostring(err))
assert(err:find("rebuild it against JITLua headers", 1, true),
       "the rejection must say how to fix it: " .. tostring(err))
print("abi_probe: PUC-built module rejected")
