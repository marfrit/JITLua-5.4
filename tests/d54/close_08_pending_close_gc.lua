--! modes: A,B
--! timeout: 120
-- The pending to-be-closed values of an unwinding must stay reachable while
-- the earlier handlers run.
--
-- The __close handlers of a <close> chain run deepest-first, from C, after the
-- error has been caught. The slots that are not closed yet sit above the
-- catching frame, where the handler call frames also live. If a pending slot
-- is left above the thread's top marker, the collector does not mark it (and,
-- in this tree, the atomic phase nils everything above that marker), so the
-- value can be collected before its handler runs and the handler sees a
-- different error object or none at all.
--
-- PUC keeps every un-closed slot below the top: luaF_close walks the list from
-- the highest slot down and luaD_seterrorobj(status, level+1) puts the top just
-- above the slot it is closing, so all lower (still pending) slots stay marked.
--
-- Three chained closers. Each one collects, runs a full cycle and reports
-- whether the *next* closer's object is still alive (a __gc on it says so),
-- then raises its own error, which starts the next handler.

local collected = {}
local function closable (tag)
  return setmetatable({ tag = tag }, {
    __gc = function (self) collected[#collected+1] = self.tag end,
    __close = function (self, err) error("from-" .. self.tag, 0) end,
  })
end

local function probe (n)
  local mark = {}
  for i = 1, n do
    -- Each object is referenced only by its pending slot and by `mark`, which
    -- the closers below can see only through that slot. Drop the local name.
    local x <close> = closable("obj" .. i)
    mark = nil
    local y <close> = closable("inner" .. i)
    error("start" .. i, 0)
  end
end

for round = 1, 3 do
  collected = {}
  local ok, msg = pcall(probe, 3)
  print("round", round, "ok", ok, "msg", tostring(msg))
  table.sort(collected)
  print("round", round, "finalized during the chain:", #collected,
	table.concat(collected, ","))
  collectgarbage()
  collectgarbage()
  print("round", round, "finalized after the round:", #collected,
	table.concat(collected, ","))
end

-- A yield-free chain that only closes on a normal block exit, same shapes, for
-- the level the values live at.
do
  collected = {}
  local order = {}
  local function c (tag)
    return setmetatable({}, {
      __close = function (self, err)
	order[#order+1] = tag
	collectgarbage()
	collectgarbage()
      end,
      __gc = function (self) collected[#collected+1] = tag end,
    })
  end
  do
    local a <close> = c("a")
    do local b <close> = c("b") end
    local e <close> = nil  -- false: nothing to close
  end
  print("block exit order:", table.concat(order, ","))
  print("block exit collected:", #collected)
end
