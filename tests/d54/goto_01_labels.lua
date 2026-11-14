--! §4.2 goto/::label:: 5.4 scoping rules (2.1 already has goto; align rules)
local function p(...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(table.concat(t, " | "))
end
local function chunk(src)
  local f, err = load(src)
  if not f then return "PARSE_ERR: " .. tostring(err):gsub("^.-:%d+: ", "") end
  local ok, res = pcall(f)
  if not ok then return "RUN_ERR: " .. tostring(res):gsub("^.-:%d+: ", "") end
  return tostring(res)
end
p("label end", chunk("do goto continue ::continue:: end return 1"))
p("label last stmt", chunk("do goto l ::l:: end return 2"))
p("forward local", chunk("goto l local x = 1 ::l:: return 3"))
p("jump into scope", chunk("do goto l local x = 1 ::l:: end return 4"))
p("jump out of scope", chunk("do local x = 1 goto l end ::l:: return 5"))
p("dup label", chunk("::l:: ::l:: return 6"))
p("dup nested", chunk("do ::l:: end do ::l:: end return 7"))
p("undefined", chunk("goto nowhere return 8"))
p("break via goto", chunk("for i=1,3 do if i==2 then goto continue end ::continue:: end return 9"))
p("loop exit", chunk("local n=0 for i=1,10 do n=n+1 if i==3 then goto done end end ::done:: return n"))
p("nested blocks", chunk("do do goto l end ::l:: end return 10"))
p("label in repeat", chunk("repeat goto l ::l:: break until true return 11"))
p("goto backward", chunk("local i=0 ::top:: i=i+1 if i<3 then goto top end return i"))
p("label visibility", chunk("do ::l:: end goto l return 12"))
p("void label", chunk("::l:: return 13"))
p("label then end", chunk("do ::l:: end return 14"))
p("goto in while", chunk("local i=0 while true do i=i+1 if i>2 then goto out end end ::out:: return i"))
