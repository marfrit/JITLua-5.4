-- Stage timer for the k-nucleotide benchmark (analysis probe, not a change to
-- the benchmark). Mirrors .dlcache/bench/src/k-nucleotide.lua statement for
-- statement, but prints a per-stage os.clock() line to stderr so the driver can
-- attribute the whole-process time. stdout is the real benchmark output.
local T = os.clock
local t0 = T()

local function kfrequency(seq, freq, k, frame)
  local sub = string.sub
  local k1 = k - 1
  for i=frame,string.len(seq)-k1,k do
    local c = sub(seq, i, i+k1)
    freq[c] = freq[c] + 1
  end
end

local function freqdefault()
  return 0
end

local function count(seq, frag)
  local k = string.len(frag)
  local freq = setmetatable({}, { __index = freqdefault })
  for frame=1,k do kfrequency(seq, freq, k, frame) end
  io.write(freq[frag] or 0, "\t", frag, "\n")
end

local function frequency(seq, k)
  local freq = setmetatable({}, { __index = freqdefault })
  for frame=1,k do kfrequency(seq, freq, k, frame) end
  local sfreq = {}
  local sn = 0
  for c,v in pairs(freq) do sn = sn + 1; sfreq[sn] = c end
  table.sort(sfreq, function(a, b)
    local fa, fb = freq[a], freq[b]
    return fa == fb and a > b or fa > fb
  end)
  sum = string.len(seq)-k+1
  for _,c in ipairs(sfreq) do
    io.write(string.format("%s %0.3f\n", c, (freq[c]*100)/sum))
  end
  io.write("\n")
end

local function readseq()
  local sub = string.sub
  for line in io.lines() do
    if sub(line, 1, 1) == ">" and sub(line, 2, 6) == "THREE" then break end
  end
  local lines = {}
  local ln = 0
  for line in io.lines() do
    local c = sub(line, 1, 1)
    if c == ">" then break
    elseif c ~= ";" then ln = ln + 1; lines[ln] = line end
  end
  return string.upper(table.concat(lines, "", 1, ln))
end

local t1 = T()
local seq = readseq()
local t2 = T()
frequency(seq, 1)
local t3 = T()
frequency(seq, 2)
local t4 = T()
count(seq, "GGT")
local t5 = T()
count(seq, "GGTA")
local t6 = T()
count(seq, "GGTATT")
local t7 = T()
count(seq, "GGTATTTTAATT")
local t8 = T()
count(seq, "GGTATTTTAATTTATAGT")
local t9 = T()
io.stderr:write(string.format(
  "PROBE readseq=%.2f freq1=%.2f freq2=%.2f c3=%.2f c4=%.2f c6=%.2f c12=%.2f c18=%.2f " ..
  "work=%.2f total=%.2f len=%d\n",
  (t2-t1)*1000, (t3-t2)*1000, (t4-t3)*1000, (t5-t4)*1000, (t6-t5)*1000,
  (t7-t6)*1000, (t8-t7)*1000, (t9-t8)*1000, (t9-t1)*1000, (t9-t0)*1000, #seq))
