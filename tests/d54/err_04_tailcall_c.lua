--! §4.2 tail calls into C functions: error names, levels and stack usage.
--!
--! PUC 5.4 does not really tail-call a C function: the Lua caller frame stays
--! alive and the C function runs in a new frame. Error names resolve from the
--! CALLT site, error(...,2) points at the caller, and recursion through a
--! tail-called C function consumes Lua stack (bounded by the C-call limit).
--! LuaJIT keeps the caller frame for a tail call to a C function too (via an
--! LJ_CONT_TAILRET continuation frame), so all of the above match PUC.
local function show(label, f)
  local ok, a = pcall(f)
  if ok then
    print(label .. " ok " .. tostring(a))
  else
    print(label .. " err " .. tostring(a):gsub("^.-:%d+: ", ""))
  end
end

-- Warm up traces that contain tail calls into C functions. The error names
-- below must be identical with the JIT on and off (-jon vs -joff).
local warm = 0
local function step()
  return pcall(string.rep, "x", 1)
end
for _ = 1, 20000 do
  local ok, v = step()
  if ok then warm = warm + #v end
end
print("warm " .. warm)

-- Short name of the C function, resolved from the CALLT site.
show("tail rep", function() return string.rep(nil, 1) end)
show("tail move", function() return table.move(nil, 1, 1, 1) end)
show("tail tonumber", function() return tonumber("1", 1) end)

-- error(..., 2) attributes the message to the caller of the erroring function.
show("tail error2", function() return error("boom", 2) end)

-- __call metamethod that resolves to a C function, in tail position.
local callrep = setmetatable({}, {__call = function(_, s, n) return string.rep(s, n) end})
show("tail callmm", function() return callrep("x", 3) end)
local badrep = setmetatable({}, {__call = string.rep})
show("tail callmm err", function() return badrep(nil, 1) end)

-- Many tail calls into C functions release the caller frame again.
local total = 0
for _ = 1, 100000 do
  local ok, v = step()
  if ok then total = total + #v end
end
print("loop total " .. total)

-- Tail calls into C inside a coroutine (small stack) stay bounded.
local co = coroutine.create(function()
  local n = 0
  for _ = 1, 50000 do
    local ok, v = step()
    if ok then n = n + #v end
  end
  return n
end)
print("coro " .. tostring(select(2, coroutine.resume(co))))

-- Recursion through a tail-called C function is bounded and catchable.
local depth = 0
local function rec()
  depth = depth + 1
  return pcall(rec)
end
rec()
print("rec bounded " .. tostring(depth > 0 and depth < 1000000))
