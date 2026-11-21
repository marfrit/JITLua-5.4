--! modes: A
--! timeout: 60
-- Parser limit messages: PUC words them "too many X (limit is N) in <where>"
-- (lparser.c errorlimit). Where the limit is the same limit, the wording must
-- match. Only the *depth* at which a deeply nested chunk is refused differs by
-- design: PUC's parser recurses and its C-call bound stops it ("C stack
-- overflow"), this tree counts nesting levels (synlevel_begin, LJ_MAX_XLEVEL)
-- and reports its own expression limits -- see docs/DIFFERENCES.md, so for the
-- nesting shapes only the yes/no is compared, not the message.

local function limitmsg (s)
  local f, msg = load(s)
  if f then return "LOADED" end
  -- The PUC wording, without the " near <token>" tail the lexer appends.
  return tostring((string.match(tostring(msg), "too many .-%(limit is %d+%) in [a-z]+")
		   or string.match(tostring(msg), "too many")
		   or ("NO-SUCH-WORDING: " .. tostring(msg))))
end

local function refused (s) return load(s) == nil end

local function rep (n, s) return string.rep(s, n) end

-- The ten shapes of the PUC suite (errors.lua, "testing syntax limits"): the
-- 100-level version must load, the 500-level version must be refused.
local cases = {
  {"local a; a", ",a", "= 1", ",1"},
  {"local a; a=", "{", "0", "}"},
  {"return ", "(", "2", ")", ""},
  {"local function a (x) return x end; return ", "a(", "2.2", ")", ""},
  {"", "do ", "", " end"},
  {"", "while a do ", "", " end"},
  {"local a; ", "if a then else ", "", " end"},
  {"", "function foo () ", "", " end"},
  {"local a = ''; return ", "a..", "'a'", "", ""},
  {"local a = 1; return ", "a^", "a", "", ""},
}
for i, c in ipairs(cases) do
  print("case", i, "100 loads:", load(c[1] .. rep(100, c[2]) .. c[3] .. rep(100, c[4])) ~= nil,
	"500 refused:", refused(c[1] .. rep(500, c[2])))
end

-- The limits PUC names by count and whose number is the same here: local
-- variables (200 on both sides) and upvalues (255 on both sides, so 210 must
-- load). Here the wording must be PUC's.
names = {}
for i = 1, 210 do names[i] = "v" .. i end
print("many locals:", limitmsg("local " .. table.concat(names, ", ")))
print("many locals in a function:",
      limitmsg("function f() local " .. table.concat(names, ", ") .. " end"))
local ups = {}
for i = 1, 210 do ups[i] = "u" .. i end
print("210 upvalues load:",
      load("do local " .. table.concat(ups, ", ") .. " return function () end end") ~= nil)
ups = {}
for i = 1, 260 do ups[i] = "u" .. i end
print("many upvalues:", limitmsg("do local " .. table.concat(ups, ", ") ..
  " return function () end end"))
