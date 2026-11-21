--! §3.2 error wording: PUC 5.4 names a non-callable metamethod value
--! ("attempt to call a number value (metamethod 'add')", luaG_typeerror on the
--! metamethod) and uses a metatable's __name in type/compare errors
--! (luaT_objtypename). luaL_newmetatable sets __name = tname in 5.4, so the io
--! and corpus file handles report "FILE*" instead of "userdata".
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end

local function has(s, sub)
  return s ~= nil and string.find(s, sub, 1, true) ~= nil
end

-- arithmetic metamethod that is not callable
do
  local a = setmetatable({}, {__add = 34})
  local ok, msg = pcall(function() return a + 1 end)
  p("add", ok, has(msg, "attempt to call a number value"),
    has(msg, "(metamethod 'add')"))
end

-- ordered comparison metamethod that is not callable
do
  local a = setmetatable({}, {__lt = {}})
  local ok, msg = pcall(function() return a > a end)
  p("lt", ok, has(msg, "attempt to call a table value"),
    has(msg, "(metamethod 'lt')"))
end

-- a callable __call chain on the metamethod value still works
do
  local a = setmetatable({}, {__add = setmetatable({}, {__call = function() return 7 end})})
  p("callchain", a + 1)
end

-- __name of tables in comparison errors
do
  local mt = {__name = "My Type"}
  local x = setmetatable({}, mt)
  local y = setmetatable({}, mt)
  local ok, msg = pcall(function() return x < y end)
  p("two", has(msg, "two My Type values"))
  ok, msg = pcall(function() return {} < x end)
  p("with", ok, has(msg, "table with My Type"))
end

-- io handles are registered with luaL_newmetatable("FILE*"), so __name is set
do
  local f = io.stdout
  local ok, msg = pcall(function() return ~f end)
  p("file", ok, has(msg, "FILE*"))
end
