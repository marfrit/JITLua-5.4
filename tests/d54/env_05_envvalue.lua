--! PENDING (VM work, branch wip-calls-vm): PUC 5.4 accepts any value as the
--! environment of load()/loadfile() -- a non-table env is stored with the
--! function and _ENV resolves to it (PUC src/lbaselib.c load_aux sets it as
--! the 1st upvalue via lua_setupvalue; PUC testes/calls.lua:359 asserts
--! load("return _ENV", nil, nil, 123)() == 123). LuaJIT stores only a table
--! as a function environment (src/lib_base.c load_aux: tvistab/tvisnil
--! only): a non-table env value is silently ignored and _ENV falls back to
--! the global table, so the chunk's _ENV is a table here, not the value.
local function probe(name, envval)
  local f, err = load("return _ENV", nil, nil, envval)
  if not f then
    print(name, "load-failed", tostring(err):gsub("^.-:%d+: ", ""))
    return
  end
  local e = f()
  print(name, type(e), e == envval)
end
probe("number env", 123)
probe("string env", "the env")
probe("function env", function() end)
probe("boolean env", true)
-- loading itself succeeds with a non-table env on both sides when the
-- chunk does not touch _ENV
print("load ok", pcall(load, "return 1", nil, nil, 123))
