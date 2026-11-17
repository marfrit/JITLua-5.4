--! §4.2 message-handler re-entry is bounded by the C-call limit (PUC 5.4).
--! A handler that errors after resetting the protected status (via pcall) is
--! re-entered; the cascade must terminate with "error in error handling"
--! instead of recursing without a bound.
local count = 0
local function fail ()
  count = count + 1
  if count < 1000 then
    pcall(function () error("reset") end)
    error("handler")
  end
end
local err, msg = xpcall(function () error("body") end, fail)
print(err, msg)
