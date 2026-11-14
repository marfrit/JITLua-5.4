--! §4.3 string.dump round-trip + strip flag; §4.2 string lib 5.4 rules
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local f = load("local x = 1 return x + 2")
p("dump type", type(string.dump(f)))
p("dump reload", (function() local g = assert(load(string.dump(f))) return g() end)())
p("dump strip", (function()
  local ok, d = pcall(string.dump, f, true)
  if not ok then return "no strip arg" end
  local g = assert(load(d))
  return #string.dump(f) > #d, g()
end)())
p("dump header", (function() local d = string.dump(f) return string.format("%02x%02x%02x%02x", d:byte(1, 4)) end)())
p("dump upvalue", (function()
  local u = 5
  local h = load("return u")
  local ok, err = pcall(string.dump, h)
  return ok, ok and "dumped" or tostring(err):gsub("^.-:%d+: ", "")
end)())
p("dump c func", pcall(string.dump, print))
p("dump load err", pcall(load, "not a chunk"), pcall(load, "\27bad"))
p("rep", string.rep("ab", 3), string.rep("ab", 3, "-"), string.rep("x", 0), string.rep("x", -1))
p("rep err", pcall(string.rep, "x", 2 ^ 62), pcall(string.rep, "x", 1, 2 ^ 62))
p("sub", string.sub("abcdef", 2, 4), string.sub("abcdef", -3), string.sub("abcdef", 2),
  string.sub("abcdef", 0), string.sub("abcdef", 5, 2), string.sub("abcdef", -10, 10))
p("find", string.find("hello world", "o"), string.find("hello", "l+"), string.find("a.b", ".", 1, true))
p("find caps", string.find("abcabc", "(b)(c)", 2))
p("match", string.match("key=value", "(%w+)=(%w+)"), string.match("abc", "%d"))
p("gmatch", (function() local t = {} for w in string.gmatch("a,b,,c", "[^,]*") do t[#t + 1] = w end return table.concat(t, "|") end)())
p("gsub", string.gsub("abc", "b", "X"), string.gsub("abc", "(b)", "%1%1"),
  string.gsub("abc", "b", function() return "X" end), string.gsub("abc", "b", { b = "Y" }))
p("gsub err", pcall(string.gsub, "abc", "b", {}), pcall(string.gsub, "a", "a", "%2"))
p("byte char", string.byte("abc", 1, -1), string.char(65, 66), string.byte("abc", -1))
p("case", string.upper("aBc"), string.lower("aBc"), ("aBc"):upper())
p("format q roundtrip", (function()
  local s = 'a"b\\c\nd\0e\255'
  return load("return " .. string.format("%q", s))() == s
end)())
p("len reverse", string.len("abc"), string.reverse("abc"), ("abc"):len())
p("str index", ("abc"):sub(2), ("%d"):format(5), ("abc").byte ~= nil)
