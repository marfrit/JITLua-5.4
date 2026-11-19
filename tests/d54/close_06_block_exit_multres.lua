--! §3.3.8 to-be-closed variables: a block exit calls __close from the same
--! bytecode that closes upvalues, and that code keeps the count of open
--! results alive for `return f()` in a <close> scope. At every other block
--! exit there are no open results, and the count is whatever the VM last had
--! in that place: after a store of a new string key it was half a pointer on
--! x86_64, and the __close call frame was placed far outside the stack.
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

-- The reduced program: new key stored in the variable, then the block ends.
local function f()
  local t = {}
  do
    local t2 <close> = setmetatable({}, {__close = function() t.closed = true end})
    t2.what = "ever"
  end
  return t.closed
end
p("block exit after a new key", pcall(f))

-- Loop bodies, break and goto out of the scope, after stores and other
-- instructions that use the VM's temporaries.
local function g(n)
  local log = {}
  for i = 1, n do
    local c <close> = setmetatable({}, {__close = function() log[#log + 1] = i end})
    c["k" .. i] = i
    c.x = i * 2.5
    c[i] = "v" .. i
    c.y = c.x .. c[i]
    if i == n - 1 then break end
  end
  return #log, log[1], log[#log]
end
p("loop with break", g(50))

local function gt()
  local log = {}
  do
    local a <close> = setmetatable({}, {__close = function() log[#log + 1] = "a" end})
    do
      local b <close> = setmetatable({}, {__close = function() log[#log + 1] = "b" end})
      b.new1, b.new2 = 1, 2
      a.new3 = tostring(b.new1 + b.new2)
      goto out
    end
  end
  ::out::
  return table.concat(log, ",")
end
p("goto out of two scopes", gt())

-- return f() in a <close> scope: here the count is live, and the open
-- results have to survive the __close call.
local function h(n)
  local big, order = {}, {}
  for i = 1, n do big[i] = i end
  local function inner()
    local c <close> = setmetatable({}, {__close = function() order[#order + 1] = "closed" end})
    c.field = "new"
    return table.unpack(big, 1, n)
  end
  local r = table.pack(inner())
  return r.n, r[1], r[n], order[1]
end
for _, n in ipairs{0, 1, 2, 3, 50, 300} do p("open results", n, h(n)) end

-- The same in a loop that gets compiled or stitched.
local cnt = 0
local mt = {__close = function() cnt = cnt + 1 end}
for i = 1, 3000 do
  local c <close> = setmetatable({}, mt)
  c.what = i
end
p("hot loop", cnt)

-- An error from a __close at a block exit is an ordinary error.
p("error in __close", pcall(function()
  do
    local c <close> = setmetatable({}, {__close = function() error("in close", 0) end})
    c.what = "ever"
  end
  return "not reached"
end))
