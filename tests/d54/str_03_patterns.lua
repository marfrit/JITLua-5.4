--! §4.2 string patterns (Lua 5.4.9 exactness: %f, %b, classes, gmatch init,
--! gsub empty-match/lastmatch rules, %0 replacement and error wording)
-- Output is byte-identical under PUC 5.4.9 and JITLua-5.4.

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function show(tag, ...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "string" then parts[#parts + 1] = hex(v)
    else parts[#parts + 1] = tostring(v) end
  end
  print(tag .. ": " .. table.concat(parts, " "))
end
local function err(tag, f, ...)
  local ok, a = pcall(f, ...)
  show(tag, ok, a)
end
local function collect(s, p, init)
  local t, n = {}, 0
  if init == nil then
    for m in string.gmatch(s, p) do n = n + 1; t[n] = m end
  else
    for m in string.gmatch(s, p, init) do n = n + 1; t[n] = m end
  end
  return n, table.concat(t, ",")
end

-- %f frontier: start of subject is previous '\0'; negated sets; embedded NUL.
show("f-simple", string.find("a", "%f[a]"))
show("f-not-z", string.find("a", "%f[^%z]"))
show("f-not-l", string.find("a", "%f[^%l]"))
show("f-a-z", string.find("aba", "%f[a%z]"))
show("f-z", string.find("aba", "%f[%z]"))
show("f-l-z", string.find("aba", "%f[%l%z]"))
show("f-not-l-z", string.find("aba", "%f[^%l%z]"))
show("f-w", string.find("a", "%f[%w]"))
show("f-a", string.find("a", "%f[%a]"))
show("f-gsub-wa", string.gsub("aaa aa a aaa a", "%f[%w]a", "x"))
show("f-gsub-set", string.gsub("[[]] [][] [[[[", "%f[[].", "x"))
show("f-gsub-d", string.gsub("01abc45de3", "%f[%d]", "."))
show("f-gsub-D", string.gsub("01abc45 de3x", "%f[%D]%w", "."))
show("f-gsub-range", string.gsub("function", "%f[\1-\255]%w", "."))
show("f-gsub-notrange", string.gsub("function", "%f[^\1-\255]", "."))
show("f-nul", string.find("a\0b", "%f[%z]"))
show("f-nul-not", string.find("a\0b", "%f[^\0]"))
show("f-nul-class", string.find("a\0b", "%f[^\0-\0]b"))

-- %b balanced: nesting, same delimiter, empty inner, unmatched end.
show("b-nested", string.match("(a(b)c)", "%b()"))
show("b-empty", string.match("()", "%b()"))
show("b-double", string.match("(())", "%b()"))
show("b-same", string.match("|a|b|", "%b||"))
show("b-unmatched", string.match("(abc", "%b()"))
show("b-nul", string.match("abc\0efg\0\1e\1g", "%b\0\1"))
show("b-gsub", string.gsub("alo 'oi' alo", "%b''", '"'))
err("b-err", string.find, "a", "%b")
err("b-err-short", string.find, "a", "%ba")

-- classes and bracket sets, including embedded NUL and escaped punctuation.
show("c-range-nul", string.match("ab\0\1\2c", "[\0-\2]+"))
show("c-range-nul-one", string.match("ab\0\1\2c", "[\0-\0]+"))
show("c-z", string.match("abc\0", "%z"))
show("c-Z", string.match("abc\0", "%Z"))
show("c-dot-nul", string.match("\0", "."))
show("c-punct", string.match("abc-", "[%p]+"))
show("c-not-alpha", string.match("abc x", "[^%a]+"))
show("c-lower", string.match("azAZ", "[%l]+"))
show("c-upper", string.match("azAZ", "[%u]+"))
show("c-digit", string.match("a12b", "%d+"))
show("c-space", string.match(" \t", "%s+"))
show("c-xdigit", string.match("0aF", "%x+"))
show("c-word", string.match("a1_", "%w+"))
show("c-graph", string.match("g", "%g"), string.match("\1", "%g"))
show("c-not-graph", string.match("g", "%G"), string.match("\1", "%G"))
show("c-ctrl", string.match("\1", "%c"), string.match("\1", "%C"))
show("c-escaped-bracket", string.match("]", "[%]]"))
show("c-escaped-dash", string.match("a-z", "[a%-z]+"))
show("c-negated-range", string.match("abc x", "[^a-c]+"))
show("c-set-nul", string.match("x\0y", "[%\0]"))

-- gmatch: init argument (5.4) and empty-match advance (lastmatch) rules.
show("gm-init-3", collect("10 20 30", "%d+", 3))
show("gm-init-neg", collect("11 21 31", "%d+", -4))
show("gm-init-end", collect("11 21 31", "%w*", 9))
show("gm-init-past-end", collect("11 21 31", "%w*", 10))
show("gm-init-zero", collect("abc", "b", 0))
show("gm-empty", collect("abc", ""))
show("gm-space", collect("a  \nbc\t\td", "()%s*()"))
show("gm-pos", collect("abcde", "()"))
show("gm-frontier", collect("alo alo th02 is 1hat", "()%f[%w%d]"))

-- gsub: empty-match rules, %0 and %% replacement, position captures.
show("gs-empty", string.gsub("abc", "", "-"))
show("gs-cstar", string.gsub("abc", "c*", "-"))
show("gs-astar", string.gsub("a b cd", " *", "-"))
show("gs-dollar-empty", string.gsub("", "^", "r"), string.gsub("", "$", "r"))
show("gs-zero", string.gsub("abc=xyz", "(%w*)(%p)(%w+)", "%3%2%1-%0"))
show("gs-zero-plain", string.gsub("abc", "%w", "%1%0"), string.gsub("abc", "%w+", "%0%1"))
show("gs-percent", string.gsub("abc", "b", "%%"), string.gsub("abc", "b", "%%%%"))
show("gs-nul-repl", string.gsub("áéí", "$", "\0óú"))
show("gs-pos", string.gsub("alo alo", "()[al]", "%1"))
show("gs-max", string.gsub("abçd", "(.)", "%0@", 2))
show("gs-table", string.gsub("alo alo", "(.)", {a = "AA", l = ""}))
show("gs-table-miss", string.gsub("alo alo", ".", {}))
show("gs-func", string.gsub("alo alo", "%w+", function(w) return "<" .. w .. ">" end, 1))
err("gs-badcap", string.gsub, "alo", ".", "%2")
err("gs-badcap0", string.gsub, "alo", "(%0)", "a")
err("gs-badcap1", string.gsub, "alo", "(%1)", "a")
err("gs-badrep", string.gsub, "alo", ".", "%x")
err("gs-trailing-percent", string.gsub, "alo", ".", "%")

-- find/match: init bounds (negative, 0, len+1, past end), plain, captures.
show("fd-init-zero", string.find("abc", "b", 0))
show("fd-init-neg1", string.find("abc", "b", -1))
show("fd-init-neg2", string.find("abc", "b", -2))
show("fd-init-neg3", string.find("abc", "b", -3))
show("fd-init-neg4", string.find("abc", "b", -4))
show("fd-init-end", string.find("abc", "", 4))
show("fd-init-past", string.find("abc", "", 5))
show("fd-init-past-b", string.find("abc", "b", 5))
show("fd-plain", string.find("a.b", ".", 1, true))
show("fd-pattern", string.find("a.b", "%."))
show("fd-poscaps", string.find("abc", "()b()"))
show("mt-poscaps", string.match("abc", "()b()"))
show("mt-no-caps", string.match("abc", "b"))
show("fd-anchor", string.find("abcabc", "^abc", 2), string.find("abcabc", "^abc"))

-- malformed patterns: PUC 5.4 error wording.
local function malform(tag, p) err(tag, string.find, "a", p) end
malform("mf-unfinished", "(.")
malform("mf-bad-close", ".)")
malform("mf-missing-close", "[a")
malform("mf-empty-set", "[]")
malform("mf-neg-empty-set", "[^]")
malform("mf-set-esc-close", "[a%]")
malform("mf-set-esc-end", "[a%")
malform("mf-b-noargs", "%b")
malform("mf-b-onearg", "%ba")
malform("mf-ends-percent", "%")
malform("mf-f-no-bracket", "%f")

print("OK")
