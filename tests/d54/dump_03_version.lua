--! Fork dump-format guard: the fork bump uses a private version >= 0x80 so
--! stock LuaJIT 2.1 dumps cannot be misparsed and vice versa. Our own dumps
--! round-trip; a version-2 header is rejected with the normal bad-format error.
--! Not comparable to PUC 5.4.9 (different dump format entirely); harness marks
--! A/B known-bad and mode R exercises it.
local f = assert(load("return 1, 'str', 1 << 40"))
local d = string.dump(f)
local g, err = load(d)
print("roundtrip", g ~= nil, err == nil, g and select("#", g()), g and g() == 1)
-- Stock LuaJIT 2.1 header: ESC L J version 2, flags 0, chunkname and truncated body.
local bad = string.char(27, 76, 74, 2, 0, 1, 0)
local h, hem = load(bad)
print("v2 rejected", h == nil, type(hem), hem ~= nil)
-- Our own version byte is >= 0x80.
print("version byte", string.byte(d, 4) >= 0x80)
