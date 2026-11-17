local s = string.rep("ACGTACGTACGT", 20000)
local function def() return 0 end
for _,K in ipairs({3, 12, 18}) do
  local freq = setmetatable({}, {__index=def})
  local t0 = os.clock()
  for i=1,#s-K+1,K do
    local c = string.sub(s,i,i+K-1)
    freq[c] = freq[c] + 1
  end
  print("K",K,"sec",os.clock()-t0)
end
