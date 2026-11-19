--! The GC check at the head of a weak loop, taken often and with many values
--! live across it: integer, float and 64-bit accumulators are carried in
--! registers over the check, and the step itself runs on almost every
--! iteration (tiny pause, allocation in the body). The slow path of the check
--! must not disturb any of them. Values are compared between the arms.
collectgarbage("setpause", 1)
collectgarbage("setstepmul", 1)

local function run(x, N)
  local a, b, c, d = 1, 2, 3, 4
  local f, g = 0.5, 1.25
  local h, k = 0x100000000, 0x7fffffff00000001
  local s, n = "", 0
  while x[1] and n < N do
    s = n .. ":" .. a
    a = a + n
    b = b ~ a
    c = c + (b & 0xff)
    d = d - c % 7
    f = f + g * 0.5
    g = g + 0.001
    h = h + n * 3
    k = k ~ (h << 1)
    n = n + 1
  end
  return a, b, c, d, f, g, h, k, #s, n
end

local jit = rawget(_G, "jit")
for round = 1, 3 do
  if jit then jit.flush() end
  local keep = {}
  local x = setmetatable({[1] = keep}, {__mode = "v"})
  print(round, run(x, 20000))
  assert(x[1] == keep)
end
collectgarbage("setpause", 200)
collectgarbage("setstepmul", 200)
print("ok")
