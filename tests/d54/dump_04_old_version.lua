--! A binary chunk written by an older dump format must be rejected by the
--! loader's version check, not loaded and run: the format changed when the
--! parser started to keep table constructors and closures at the free
--! register (the VM narrows the live top to dst+1 there), so the bytecode of
--! an older dump runs wrong. Here the version byte of a fresh dump is set to
--! the previous fork format version (0x84); the body is irrelevant, the header
--! decides. PUC 5.4.9 rejects a chunk whose version byte is not its own
--! (lundump.c checkHeader), so in both arms the patched chunk does not load.
--! Only the outcome is printed: the messages differ (private dump format).
local f = assert(load("local t = {1, 2}; return #t, 'str'"))
local d = string.dump(f)
local g = load(d, "=fresh", "b")
print("fresh dump loads", g ~= nil, g and g())
local old = d:sub(1, 3) .. string.char(0x84) .. d:sub(5)
local h, err = load(old, "=old", "b")
print("old version rejected", h == nil, type(err))
-- a version byte one above ours is rejected as well
local v = d:byte(4)
local newer = d:sub(1, 3) .. string.char((v + 1) % 256) .. d:sub(5)
local h2, err2 = load(newer, "=newer", "b")
print("newer version rejected", h2 == nil, type(err2))
