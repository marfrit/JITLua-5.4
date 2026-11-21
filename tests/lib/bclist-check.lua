-- Check the jump targets of a `luajit -bl` listing (read from the file named
-- by arg[1]): every "=> NNNN" operand must name a bytecode position of the
-- same function, and that position must carry the "=>" target marker. The
-- listing must contain at least one backward and one forward jump, so the
-- check can fail. Prints one summary line; exits non-zero on a bad target.
local fh = assert(io.open(assert(arg[1], "listing file expected"), "r"))
local text = fh:read("a"); fh:close()
local bad, nback, nfwd, njmp, nfunc = 0, 0, 0, 0, 0
for block in text:gmatch("%-%- BYTECODE %-%-[^\n]*\n(.-)\n\n") do
  nfunc = nfunc + 1
  local marked, jumps, maxpc = {}, {}, 0
  for line in block:gmatch("[^\n]+") do
    local pc, mark = line:match("^(%d%d%d%d) (..)")
    if pc then
      pc = tonumber(pc); if pc > maxpc then maxpc = pc end
      if mark == "=>" then marked[pc] = true end
      local tgt = line:match("=> (%d+)%s*$")
      if tgt then jumps[#jumps + 1] = {pc, tonumber(tgt), line} end
    end
  end
  for _, j in ipairs(jumps) do
    local pc, tgt, line = j[1], j[2], j[3]
    njmp = njmp + 1
    if tgt < 1 or tgt > maxpc or not marked[tgt] then
      bad = bad + 1
      print("bad jump target: " .. line)
    elseif tgt <= pc then nback = nback + 1 else nfwd = nfwd + 1 end
  end
end
print(string.format("bclist: %d functions, %d jumps (%d backward, %d forward), %d bad",
  nfunc, njmp, nback, nfwd, bad))
if bad > 0 or nback == 0 or nfwd == 0 then os.exit(1) end
