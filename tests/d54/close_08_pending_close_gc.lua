--! modes: A,B
--! timeout: 120
-- The pending to-be-closed values of an unwinding must stay reachable while
-- the earlier handlers run.
--
-- The __close handlers of a <close> chain run deepest-first, from C, after the
-- error has been caught. The slots that are not closed yet sit above the
-- catching frame, which is also where the handler call frames go. If a pending
-- slot is left above the thread's top marker, the collector does not mark it
-- and the atomic phase of this tree nils everything above that marker: the
-- value is then gone before its handler is called, the close fails or sees a
-- different value, and the wrong error propagates.
--
-- PUC keeps every un-closed slot below the top: luaF_close walks the list from
-- the highest slot down and luaD_seterrorobj(status, level+1) puts the top just
-- above the slot it is closing, so all lower (still pending) slots stay marked.
--
-- Each handler runs two full collections before it does anything else, so the
-- test is deterministic; what it reports is whether every closer ran, on its
-- own object, with the error the previous one raised.

local function closable (tag)
  return setmetatable({ tag = tag }, {
    __close = function (self, err)
      collectgarbage()
      collectgarbage()
      assert(self and self.tag == tag, "handler lost its own object: " .. tag)
      assert(err == nil or type(err) == "string",
	     "handler lost the error object: " .. tag)
      local seen = err == nil and "-" or err
      error("from-" .. tag .. "<-" .. seen, 0)
    end,
  })
end

for round = 1, 3 do
  local ok, msg = pcall(function ()
    local a <close> = closable("a")
    do
      local b <close> = closable("b")
      do
        local c <close> = closable("c")
        error("start", 0)
      end
    end
    return "unreachable"
  end)
  -- All three closers must have run, deepest first, each seeing the previous
  -- error: start -> c -> b -> a.
  print("round", round, "propagated:", tostring(msg))
end

-- The same chain on a normal block exit (no error): every closer runs with a
-- nil error object, deepest first, and collections in the middle must not
-- disturb it.
do
  local order = {}
  local function c (tag)
    return setmetatable({ tag = tag }, {
      __close = function (self, err)
        collectgarbage()
        collectgarbage()
        assert(err == nil, "unexpected error object on block exit")
        assert(self and self.tag == tag, "lost object on block exit")
        order[#order+1] = tag
      end,
    })
  end
  do
    local a <close> = c("a")
    do local b <close> = c("b") end
    local e <close> = nil  -- false: nothing to close
  end
  print("block exit order:", table.concat(order, ","))
end
