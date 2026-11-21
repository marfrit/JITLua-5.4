--! §5 io.write/f:write: floats are rendered with PUC's LUA_NUMBER_FMT
--! "%.14g" (3.0 -> "3", -0.0 -> "-0", 1e15 -> "1e+15"); integers keep the
--! integer formatter. PUC does NOT use tostring's ".0" suffix here.
--! Differential against PUC 5.4.9.
local name = os.tmpname()
local function contents()
  local g = io.open(name, "r")
  local line = g:read("l")
  g:close()
  os.remove(name)
  return line
end
local function p(label, line)
  print(label .. " | " .. line)
end

-- f:write
do
  local f = io.open(name, "w")
  local r = f:write(3, " ", 3.0, " ", -0.0, " ", 1 / 3, " ",
                    math.maxinteger, " ", 1e15, " ", -7, "\n")
  f:close()
  p("method", contents())
  print("method return | " .. tostring(r == f))
end
-- io.write through io.output
do
  local f = io.open(name, "w")
  io.output(f)
  local r = io.write(3, " ", 3.0, " ", -0.0, " ", 1 / 3, " ",
                     math.maxinteger, " ", 1e15, " ", -7, "\n")
  io.output(io.stdout)
  f:close()
  p("global", contents())
  print("global return | " .. tostring(r == f))
end

-- A hot loop keeps the JIT recorder in the picture in mode B.
local sink
for i = 1, 60 do
  local f = io.open(name, "w")
  f:write(3.0, "-", -0.0, "-", i)
  f:close()
  sink = contents()
end
p("hot last", sink)
