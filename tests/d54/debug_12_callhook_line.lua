--! modes: A,B
-- currentline in a call hook: PUC 5.4.9 calls the hook with savedpc at the
-- function's first instruction (ldo.c luaD_hookcall), so currentline is the
-- line of that instruction (ldebug.c currentline/luaG_getfuncline), not the
-- line of the 'function' keyword when the body starts further down.

local out = {}
local function hook(ev)
  local i = debug.getinfo(2, "Sl")
  if i.short_src:find("debug_12") then
    out[#out + 1] = ev .. ":" .. i.currentline .. ":" .. i.linedefined
  end
end

local function multi(a,
  b)
  local x = a
  return x
end

local function multiv(a,
  ...)

  return a
end

local function one(a) return a end

local function blank()

end

local function deep(a)
  -- comment

  -- more
  if a then
    return 1
  end
end

local t = {
  m = function(self,
    x, y)
    return x
  end
}

local function run(name, f)
  out = {}
  debug.sethook(hook, "c")
  f()
  debug.sethook()
  print(name, table.concat(out, " "))
end

run("multi", function() multi(1, 2) end)
run("multiv", function() multiv(1, 2, 3) end)
run("one", function() one(1) end)
run("blank", function() blank() end)
run("deep", function() deep(true) end)
run("method", function() t:m(1, 2) end)
run("chunk", function() load("\n\nlocal a = 1\nreturn a", "=debug_12_chunk")() end)
-- getinfo of the hooked frame from inside the hook, with "l" only
do
  local lines = {}
  debug.sethook(function()
    local i = debug.getinfo(2, "l")
    lines[#lines + 1] = i.currentline
  end, "c")
  multi(1, 2)
  debug.sethook()
  print("lines", table.concat(lines, " "))
end
