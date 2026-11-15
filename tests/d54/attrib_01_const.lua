--! §4.2 5.4 attributives: <const> (compile-time) and <close> (to-be-closed).
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function chunk(src)
  local f, err = load(src)
  if not f then return "PARSE_ERR: " .. tostring(err):gsub("^.-:%d+: ", "") end
  local ok, res = pcall(f)
  if not ok then return "RUN_ERR: " .. tostring(res):gsub("^.-:%d+: ", "") end
  return tostring(res)
end
p("const value", chunk("local x <const> = 3 return x"))
p("const assign", chunk("local x <const> = 3 x = 4 return x"))
p("const multi", chunk("local a <const>, b <const> = 1, 2 return a + b"))
p("const mixed", chunk("local a <const>, b = 1, 2 b = 3 return a + b"))
p("const noinit", chunk("local x <const> return 1"))
p("const redeclare", chunk("local x <const> = 1 local x <const> = 2 return x"))
p("const shadow", chunk("local x <const> = 1 do local x = 2 end return x"))
p("const upvalue", chunk("local x <const> = 5 local function f() return x end return f()"))
p("const captured assign", chunk("local x <const> = 5 local function f() x = 6 end return 1"))
p("const for loop", chunk("for i <const> = 1, 3 do end return 1"))
p("unknown attrib", chunk("local x <foo> = 1 return x"))
p("attrib syntax", chunk("local x <const = 1 return x"))
p("attrib noname", chunk("local x <3> = 1 return x"))
p("close parse", chunk("local x <close> = setmetatable({}, {__close=function() end}) return 1"))
p("const global", chunk("x <const> = 1 return 1"))
