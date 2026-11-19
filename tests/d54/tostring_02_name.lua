--! §6.4 __name fallback in luaL_tolstring: a table, full userdata, function,
--! thread or light userdata whose metatable has a string __name renders as
--! "NAME: 0x..." when there is no __tostring. __tostring wins over __name,
--! and a non-string __name is ignored. Plain types keep the standard names.
local function strip(e) return (tostring(e):gsub("^.-:%d+: ", "")) end
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function ts(v)
  local ok, r = pcall(tostring, v)
  if ok and type(r) == "string" then return "TS-OK:" .. r end
  if ok then return "TS-BADTYPE:" .. type(r) end
  return "TS-ERR:" .. strip(r)
end
-- The harness normalizes heap addresses to 0xADDR; the kind before it must match.
local named = setmetatable({}, { __name = "PName" })
p("tostring table name", ts(named))
p("format table name", string.format("%s", named))
p("print table name", pcall(print, named))
local plain = setmetatable({}, {})
p("tostring plain table", ts(plain))
p("format plain table", string.format("%s", plain))
-- __tostring beats __name.
local both = setmetatable({}, { __name = "N", __tostring = function() return "T" end })
p("tostring both", ts(both))
p("format both", string.format("%s", both))
-- A non-string __name falls back to the type name.
p("name number", ts(setmetatable({}, { __name = 42 })))
p("name boolean", ts(setmetatable({}, { __name = true })))
p("name empty", ts(setmetatable({}, { __name = "" })))
-- Function type metatable (debug.setmetatable sets it for the whole type).
local f = function() end
debug.setmetatable(f, { __name = "PFn" })
p("tostring function name", ts(f))
p("format function name", string.format("%s", f))
debug.setmetatable(f, { __name = "PFn", __tostring = function() return "FT" end })
p("function tostring wins", ts(f))
debug.setmetatable(f, nil)
-- Thread type metatable.
local co = coroutine.create(function() end)
debug.setmetatable(co, { __name = "PTh" })
p("tostring thread name", ts(co))
p("format thread name", string.format("%s", co))
debug.setmetatable(co, nil)
-- A string __name does not change the standard names of numbers, strings,
-- booleans and nil: 5.4 answers those before it consults the metatable.
debug.setmetatable(1, { __name = "PNum" })
p("number with name", ts(7))
p("format number with name", string.format("%s", 7))
debug.setmetatable(1, nil)
p("bool with name", ts(true))
p("string with name", ts("s"))
p("nil with name", ts(nil))
-- __name in an error message for a bad operand (PUC luaT_objtypename).
local bad = setmetatable({}, { __name = "PBad" })
p("op error name", strip((select(2, pcall(function() return bad + 1 end)))))
