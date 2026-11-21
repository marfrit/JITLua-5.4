--! §2.3: a stack overflow raised while the message handler itself is
--! overflowing the stack must be reported as "error in error handling"
--! (PUC ldo.c: luaD_growstack at ERRORSTACKSIZE -> luaD_errerr), not the
--! handler's own "stack overflow" message.
local function loop (x, y, z)
  return 1 + loop(x, y, z)
end
local res, msg = xpcall(loop, loop)
print(res, msg)

-- A handler that does not overflow keeps its own return value.
local function loop2 (x)
  return 1 + loop2(x)
end
local res2, msg2 = xpcall(loop2, function () return "handled" end)
print(res2, msg2)
