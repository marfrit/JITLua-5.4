--! §7.1 loadfile: PUC 5.4 skips an optional UTF-8 BOM and a first line that
--! starts with '#', keeping line numbers (synthetic newline).
local function run(name, data)
  local p = os.tmpname()
  local f = assert(io.open(p, "wb"))
  f:write(data)
  f:close()
  local chunk, err = loadfile(p, "t")
  local ok, res
  if chunk then ok, res = pcall(chunk) else ok, res = false, err:gsub("^.-:%d+: ", "") end
  os.remove(p)
  print(name, ok, type(res), type(res) == "string" and res:gsub(os.tmpname(), "TMP") or res)
end
run("bom", "\239\187\191print(3)")
run("shebang", "#!/usr/bin/lua\nprint(4)")
run("bom-shebang", "\239\187\191#!/usr/bin/lua\nprint(5)")
run("line1", "# comment\nprint(6)\nerror('x', 0)")
run("line2", "print(7)\nerror('x', 0)")
run("incomplete-bom", "\239")
run("hash-later", "print(8)\n# not a comment")
