--! §6.10 debug.sethook with the return mask alone ("r"): every function that
--! returns gets a return event, fast functions implemented in assembler
--! included, whether or not the call mask is set too. Printed for each
--! library function: the return events of C functions seen with "r", and
--! with "cr" for comparison. Fixed output only.
local ev
local function hook(e)
  local ar = debug.getinfo(2, "nS")
  if ar.what == "C" then ev[#ev+1] = e:sub(1, 1) .. ":" .. tostring(ar.name) end
end
local t = setmetatable({}, {__tostring = function () return "T" end})
local cases = {
  {"type", function () local x = type(1) end},
  {"tostring int", function () local x = tostring(12) end},
  {"tostring str", function () local x = tostring("s") end},
  {"tostring float", function () local x = tostring(1.5) end},
  {"tostring mm", function () local x = tostring(t) end},
  {"tonumber str", function () local x = tonumber("12") end},
  {"tonumber num", function () local x = tonumber(12) end},
  {"string.sub", function () local x = string.sub("abcd", 2) end},
  {"string.sub 3", function () local x = string.sub("abcd", 2, 3) end},
  {"string.byte", function () local x = string.byte("abcd", 2) end},
  {"string.char", function () local x = string.char(65) end},
  {"string.rep", function () local x = string.rep("a", 3) end},
  {"string.upper", function () local x = string.upper("a") end},
  {"string.reverse", function () local x = string.reverse("ab") end},
  {"method sub", function () local x = ("abc"):sub(2) end},
  {"math.abs", function () local x = math.abs(-3) end},
  {"math.floor", function () local x = math.floor(1.5) end},
  {"math.sqrt", function () local x = math.sqrt(4) end},
  {"math.max", function () local x = math.max(1, 2) end},
  {"math.min", function () local x = math.min(1, 2) end},
  {"math.exp", function () local x = math.exp(0) end},
  {"math.sin", function () local x = math.sin(0) end},
  {"select #", function () local x = select("#", 1, 2) end},
  {"select n", function () local x = select(2, 1, 2) end},
  {"rawget", function () local x = rawget({}, 1) end},
  {"rawset", function () local x = rawset({}, 1, 2) end},
  {"rawequal", function () local x = rawequal(1, 1) end},
  {"rawlen", function () local x = rawlen({}) end},
  {"next", function () local x = next({}) end},
  {"getmetatable", function () local x = getmetatable("") end},
  {"setmetatable", function () local x = setmetatable({}, nil) end},
  {"assert", function () local x = assert(1) end},
  {"ipairs", function () local x = ipairs({}) end},
  {"pairs", function () local x = pairs({}) end},
  {"ipairs iter", function () for _ in ipairs({1}) do end end},
  {"table.unpack", function () local x = table.unpack({1}) end},
  {"table.insert", function () table.insert({}, 1) end},
  {"pcall", function () local x = pcall(type, 1) end},
  {"xpcall", function () local x = xpcall(type, print, 1) end},
  {"coroutine.running", function () local x = coroutine.running() end},
  {"string.format", function () local x = string.format("%d", 1) end},
  {"string.find", function () local x = string.find("abc", "b", 1, true) end},
}
for _, c in ipairs(cases) do
  local run = c[2]
  for _, m in ipairs{"r", "cr"} do
    ev = {}
    debug.sethook(hook, m)
    run()
    debug.sethook()
    table.remove(ev, 1)  -- the return event of debug.sethook
    print(c[1], m, table.concat(ev, " "))
  end
end

-- A fast function called many times in a loop: one event per call.
do
  local n = 0
  debug.sethook(function (e)
    if debug.getinfo(2, "S").what == "C" then n = n + 1 end
  end, "r")
  for i = 1, 100 do local s = tostring(i) .. string.sub("ab", 2) end
  debug.sethook()
  print("loop", n)
end

-- Fast functions called from inside the hook get no events of their own.
do
  local tr = {}
  debug.sethook(function (e)
    local ar = debug.getinfo(2, "n")
    tr[#tr+1] = tostring(ar.name) .. "/" .. string.sub("xy", 1, 1)
  end, "r")
  local s = tostring(1)
  debug.sethook()
  print("in hook", table.concat(tr, " "))
end
