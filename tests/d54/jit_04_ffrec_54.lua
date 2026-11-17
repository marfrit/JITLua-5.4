--! §4.1 Recorded fast functions with 5.4 result types: type(), rawlen(),
--! math.abs(), math.floor(), math.ceil() in hot loops. Mode A compares the
--! printed values and math.type() with PUC, mode B the JIT with the
--! interpreter (the recorders must agree with the C functions).
local function p(label, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do
    local v = (select(i, ...))
    t[i] = tostring(v) .. (math.type(v) and ("/" .. math.type(v)) or "")
  end
  print(label, table.concat(t, " "))
end
local W, B = (1 << 40) + 3, (1 << 50) + 3
local acc = {}
for i = 1, 300 do
  acc[1] = type(i) .. type(W) .. type(B) .. type(2.5) .. type("s") .. type(nil) .. type(acc) .. type(p)
  acc[2] = rawlen({1, 2, 3}) + rawlen("abcd")
  acc[3] = math.abs(-i); acc[4] = math.abs(i - 150); acc[5] = math.abs(-2.5); acc[6] = math.abs(-W); acc[7] = math.abs(-B)
  acc[8] = math.floor(i * 0.3); acc[9] = math.ceil(i * 0.3); acc[10] = math.floor(-i * 0.3); acc[11] = math.ceil(-i * 0.3)
  acc[12] = math.floor(W); acc[13] = math.ceil(B); acc[14] = math.floor(2^40 + 0.5); acc[15] = math.ceil(-(2^40) - 0.5)
  acc[16] = math.floor(1/0); acc[17] = math.ceil(-(1/0)); acc[18] = math.floor(2^63); acc[19] = math.abs(math.mininteger)
  acc[20] = math.abs(-(2^31)); acc[21] = math.floor(-0.5); acc[22] = math.ceil(-0.5); acc[23] = math.floor(2.0); acc[24] = math.abs(-0.0)
end
p("type", acc[1])
p("rawlen", acc[2])
p("abs", acc[3], acc[4], acc[5], acc[6], acc[7])
p("floor-ceil", acc[8], acc[9], acc[10], acc[11])
p("floor-ceil-int", acc[12], acc[13], acc[14], acc[15])
p("floor-ceil-edge", acc[16], acc[17], acc[18], acc[19], acc[20])
p("floor-ceil-zero", acc[21], acc[22], acc[23], acc[24])
local ok, err = pcall(rawlen, 5)
print("rawlen-err", ok, (tostring(err):gsub("^.-:%d+: ", "")))
