--! timeout: 120
--! 5.4 parser limits on local variables (lparser.c). At most 200 locals are
--! active at a time per function (MAXVARS, errorlimit: a syntax error "too
--! many local variables (limit is 200) in main function near <token>"), and
--! a function declares at most 32767 locals in all (registerlocalvar grows
--! f->locvars up to SHRT_MAX: a runtime error "too many local variables
--! (limit is 32767)" without a position, which also goes through the message
--! handler of an enclosing xpcall). Parameters and the hidden control
--! variables of the loops count (3 for a numeric for, 4 for a generic for),
--! labels and gotos do not. There is no limit across the nested functions
--! being parsed. This tree had no 32767 limit, dropped the "near" part of
--! the 200 limit, and kept all locals, labels and gotos of the functions
--! being parsed on one variable stack of 65281 entries. A parameter list
--! over the 200 limit reported an uninitialized line. Printed: the first
--! line of each load result, the value of chunks that capture variables
--! declared after many others. (Code follows each label, so the chunk does
--! not depend on how jumps to jumps are threaded: parse_05_jump_chains.lua.)
local function try (name, src, ...)
  local f, err = load(src, "=x")
  if f then
    print(name, "ok", ...)
  else
    print(name, (tostring(err):match("^[^\n]*")))
  end
  return f
end
local function decls (n, closed, pre)
  local p = {}
  pre = pre or "a"
  for i = 1, n do
    p[#p+1] = closed and ("do local " .. pre .. i .. " end") or ("local " .. pre .. i)
  end
  return table.concat(p, "\n")
end
local function rep (s, n) return string.rep(s, n, " ") end

-- 200 active locals.
try("active 200", decls(200))
try("active 201", decls(201))
try("active 201 in function", "local function f() " .. decls(201) .. " end")
try("active 201 at a comma", "local " .. rep("a,", 200) .. "b = 1")
try("active params 201", "local function f(" .. rep("a,", 200) .. "b) end")

-- 32767 declarations per function.
try("declared 32767", decls(32767, true))
try("declared 32768", decls(32768, true))
try("declared 32768 in function", "local x\nlocal function f()\n" .. decls(32768, true) .. "\nend")
try("declared 32767 with params", "local function f(p1, p2)\n" .. decls(32765, true) .. "\nend")
try("declared 32768 with params", "local function f(p1, p2)\n" .. decls(32766, true) .. "\nend")
try("numeric for 8191", rep("for i=1,0 do end", 8191))
try("numeric for 8192", rep("for i=1,0 do end", 8192))
try("generic for 6553", rep("for k in next,{} do end", 6553) .. " local a, b")
try("generic for 6553+3", rep("for k in next,{} do end", 6553) .. " local a, b, c")
try("syntax error first", decls(32767, true) .. "\nlocal z = = 1")
try("labels do not count", decls(32000, true) .. "\n" .. rep("do ::l:: end", 2000))
print("handler", xpcall(load, function (m) return "H:" .. m end, decls(32768, true)))
print("handler syntax", xpcall(load, function (m) return "H:" .. m end, "x = = 1"))

-- No limit across the functions being parsed, and closures see the right
-- variables after many declarations, labels and gotos.
local f = try("nested 30000+30000+10000",
  decls(30000, true) .. "\nlocal cap = 40\nlocal function g()\n" ..
  decls(30000, true, "b") .. "\nlocal cap2 = 1\nlocal function h()\n" ..
  decls(10000, true, "c") ..
  "\nreturn function () cap = cap + cap2; return cap end\nend\nreturn h()\nend\n" ..
  "local k = g(); k(); return k() + cap")
if f then print("value", f()) end
f = try("gotos and labels 33000",
  "local v = 7\n" .. rep("do goto l; z = 1; ::l:: z = 2 end", 33000) ..
  "\nlocal w = 5\nreturn function () v = v + w; return v end")
if f then local k = f(); k(); print("value", k()) end
f = try("closed locals 70000",
  decls(32000, true) .. "\nlocal function g()\n" .. decls(32000, true, "b") ..
  "\nlocal u = 3\nlocal function h()\n" .. decls(6000, true, "c") ..
  "\nreturn function () return u * 2 end\nend\nreturn h()\nend\nreturn g()()")
if f then print("value", f()) end
