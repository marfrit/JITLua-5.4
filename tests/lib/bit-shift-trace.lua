-- JIT trace for bit.lshift in a hot loop; used for -jdump=+rsi.
local s = 0
for i = 1, 1000 do
  s = bit.lshift(1, i % 31)
end
print("s", s)
