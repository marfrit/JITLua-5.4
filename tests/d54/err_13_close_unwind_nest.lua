--! modes: B,R
--! §3.3.8/§4.3: __close handlers that run while an error unwinds, fail and
--! start the next round of handlers. PUC unwinds the C stack before it calls
--! the handlers, so it can go on like this for a very long time; here the
--! C frames of each failed round stay in place below the next one, and the
--! nesting of such rounds is bounded: the program ends in an error instead of
--! exhausting the native stack. Not compared with PUC (it does not finish).
--! Only the first handlers start a new round (budget), to keep the run short
--! under GC stress; without the bound each of those rounds adds up to 200 C
--! levels.
local budget
local function kind(e)
  e = tostring(e)
  if e:find("C stack overflow", 1, true) then return "C stack overflow" end
  if e:find("error in error handling", 1, true) then return "errerr" end
  if e:find("stack overflow", 1, true) then return "stack overflow" end
  return e
end

-- every handler recurses through C again, with a to-be-closed value per level
do
  local rec
  local mt = {__close = function()
    if budget > 0 then budget = budget - 1; rec() end
  end}
  function rec()
    local x <close> = setmetatable({}, mt)
    local r = string.gsub("a", ".", rec)
    return r
  end
  budget = 30
  local ok, err = pcall(rec)
  print("gsub", ok, kind(err))
end

-- the handler's own frame holds the value; the recursion below has none
do
  local big
  local mt = {__close = function()
    if budget > 0 then budget = budget - 1; big(true) end
  end}
  function big(first)
    if first then
      local z <close> = setmetatable({}, mt)
      local r = string.gsub("a", ".", big)
      return r
    end
    return string.gsub("a", ".", big)
  end
  budget = 30
  local ok, err = pcall(big, true)
  print("gsub-top", ok, kind(err))
end

-- the same through pcall levels only
do
  local rec
  local mt = {__close = function()
    if budget > 0 then budget = budget - 1; rec() end
  end}
  function rec()
    local x <close> = setmetatable({}, mt)
    assert(pcall(rec))
  end
  budget = 30
  local ok, err = pcall(rec)
  print("pcall", ok, kind(err))
end

-- afterwards the count is back: a plain recursion reaches the usual depth
do
  local n = 0
  local function foo() n = n + 1; return string.gsub("a", ".", foo) end
  print("depth", pcall(foo) == false, n)
  n = 0
  local function prec() n = n + 1; pcall(prec) end
  pcall(prec)
  print("pcall-depth", n)
end
