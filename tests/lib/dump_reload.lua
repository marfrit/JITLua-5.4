-- Mode R wrapper: execute a script through string.dump -> load -> run.
--
--   luajit tests/lib/dump_reload.lua <script.lua> [args...]
--
-- The dumped chunk keeps the original source name, so error messages and line
-- numbers are identical to a direct run; only the traceback gains one frame
-- (the harness cuts tracebacks before comparing).
--
-- Must stay parseable by unported LuaJIT 2.1 (Lua 5.1 syntax).

local target = arg and arg[1]
if not target then
  io.stderr:write("usage: dump_reload.lua <script.lua> [args...]\n")
  os.exit(1)
end

local unpack = table.unpack or unpack
local args = {}
local n = 0
for i = 2, #arg do
  n = n + 1
  args[n] = arg[i]
end

-- Mirror the standalone interpreter's arg table for the target script.
local newarg = { [0] = target }
-- Mirror the interpreter's negative arg entries (options and progname) so
-- scripts that derive 'progname' by walking negative indices can spawn the
-- interpreter exactly as in a direct run.
if arg then
  local i = -1
  while arg[i] do
    newarg[i] = arg[i]
    i = i - 1
  end
end
for i = 1, n do newarg[i] = args[i] end
arg = newarg

local f, ferr = loadfile(target)
if not f then
  -- Mimic the standalone interpreter's syntax-error report (no extra frame).
  io.stderr:write("luajit: " .. tostring(ferr) .. "\n")
  os.exit(1)
end
local dumped = string.dump(f)
local g, gerr = load(dumped)
if not g then
  io.stderr:write("luajit: " .. tostring(gerr) .. "\n")
  os.exit(1)
end
-- Unprotected on purpose: errors must reach the interpreter's top-level handler
-- exactly as they would in a direct run (same message, same exit status).
return g(unpack(args, 1, n))
