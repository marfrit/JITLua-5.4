-- GC policy read-back for tests/gcmode.sh.  Prints one key=value per line and
-- does not assert: the shell runner compares the values for each mode.
local function prev_pause()
  local old = collectgarbage("setpause", 200)
  collectgarbage("setpause", old)
  return old
end

local function prev_stepmul()
  local old = collectgarbage("setstepmul", 200)
  collectgarbage("setstepmul", old)
  return old
end

print("pause=" .. prev_pause())
print("stepmul=" .. prev_stepmul())
print("mode_inc_prev=" .. collectgarbage("incremental"))
print("mode_gen_prev=" .. collectgarbage("generational"))
collectgarbage("incremental")

-- Runtime settings must override the mode selected at startup.
collectgarbage("setpause", 137)
collectgarbage("setstepmul", 321)
print("override_pause=" .. collectgarbage("setpause", 200))
print("override_stepmul=" .. collectgarbage("setstepmul", 200))
