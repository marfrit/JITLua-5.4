--! §2.3/§4.3: a deep chain of coroutine.close calls must stop at the C-call
--! bound with PUC's error, not exhaust the native stack. Each suspended
--! coroutine's __close handler closes the next suspended coroutine, so the
--! nests are pure close calls (no resume inside the handler). PUC 5.4.9
--! errors at the close of the 198th thread with "C stack overflow", recorded
--! by the handler one level above; at depth 200000 the same error appears
--! instead of a SIGSEGV. Building the chain is sequential top-level resumes,
--! so it does not itself nest. Print exactly what PUC prints and assert the
--! failure is the bound, never a crash.
local FAILED
local function build(d)
  local cos = {}
  for i = 1, d do
    cos[i] = coroutine.create(function()
      local x <close> = setmetatable({}, {__close = function()
        if cos[i + 1] == nil then return "bottom" end
        local ok, err = coroutine.close(cos[i + 1])
        if not ok then FAILED = FAILED or {i = i, msg = err} end
        return err
      end})
      coroutine.yield()
    end)
    local ok = coroutine.resume(cos[i])
    assert(ok, "building resume at depth "..i.." failed")
  end
  return cos
end

local results = {}
for _, d in ipairs{196, 197, 198, 199, 200, 201, 202, 1000, 200000} do
  FAILED = nil
  local cos = build(d)
  local ok = coroutine.close(cos[1])
  local f = FAILED
  results[#results + 1] = {d = d, fail = f}
  io.write("d="..d.." fail="..(f and f.i or "none")..
           " msg="..(f and tostring(f.msg) or "-").."\n")
  io.flush()
end

for _, x in ipairs(results) do
  if x.d <= 197 then
    assert(x.fail == nil, "unexpected close error at depth "..x.d)
  else
    assert(x.fail and x.fail.i == 197,
           "close chain failed at "..(x.fail and x.fail.i or "none")..
           " instead of the PUC bound, depth "..x.d)
    assert(x.fail.msg == "C stack overflow",
           "wrong close error: "..tostring(x.fail.msg))
  end
end
io.write("all "..#results.." close depths clean\n")
