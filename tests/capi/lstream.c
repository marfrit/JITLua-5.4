/*
** lstream.c -- a file handle made by a C module is an io file.
** Built twice: against libluajit.a and against the PUC 5.4.9 reference, which
** is the oracle; the two outputs must be identical. The module side follows
** lauxlib.h/liolib.c: a luaL_Stream block from lua_newuserdatauv with the
** LUA_FILEHANDLE metatable, then 'f' and 'closef' set. PUC's io library takes
** such a block like its own handles: io.type, the methods, io.close (which
** calls closef), io.output/io.write and __gc/__close/__tostring. The chunk
** runs twice, the second time with the JIT off where there is one, and has
** loops that are compiled on a JIT build, including a call site that sees
** the library's own handles first and then the C stream.
*/
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static int closes;  /* calls of the stream's closef */

static int stream_close(lua_State *L)
{
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
  int ok = fclose(p->f) == 0;
  closes++;
  return luaL_fileresult(L, ok, NULL);
}

/* mkstream(): a luaL_Stream on a fresh tmpfile(), as a C module makes one. */
static int mkstream(lua_State *L)
{
  luaL_Stream *p = (luaL_Stream *)lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
  p->closef = NULL;  /* closed until the file is open (liolib newprefile) */
  luaL_setmetatable(L, LUA_FILEHANDLE);
  p->f = tmpfile();
  if (p->f == NULL) return luaL_fileresult(L, 0, "tmpfile");
  p->closef = &stream_close;
  return 1;
}

static int getcloses(lua_State *L)
{
  lua_pushinteger(L, closes);
  return 1;
}

static const char chunk[] =
  "local mk, nclose = ...\n"
  "local function p(...) print(...) end\n"
  "local function e(f, ...) local ok, m = pcall(f, ...)\n"
  "  return ok, (tostring(m):gsub('^[^:]*:%d+: ', '')) end\n"
  "local s = mk()\n"
  "p('type', io.type(s), tostring(s):match('^file %(') ~= nil)\n"
  "p('write', s:write('alpha\\n', 42, '\\n', 'beta\\n') == s)\n"
  "p('seek', s:seek('set', 0), s:seek('end'), s:seek('set'))\n"
  "p('read', s:read('l'), s:read('n'), s:read('L'), s:read('a'))\n"
  "s:seek('set', 0)\n"
  "local t = {} for l in s:lines() do t[#t+1] = l end\n"
  "p('lines', table.concat(t, ','))\n"
  "p('setvbuf', s:setvbuf('no'), s:flush())\n"
  "local old = io.output()\n"
  "p('output', io.output(s) == s, io.write('via io.write\\n') == s)\n"
  "io.output(old)\n"
  "s:seek('set', 0)\n"
  "p('back', s:read('a'):gsub('\\n', '|'))\n"
  "-- compiled loops: the C stream alone, then a call site that saw own handles\n"
  "local n0 = s:seek('end')\n"
  "for i = 1, 300 do s:write('x') end\n"
  "p('hot write', s:seek('end') - n0)\n"
  "local own = io.tmpfile()\n"
  "local files = {}\n"
  "for i = 1, 200 do files[i] = own end\n"
  "for i = 201, 300 do files[i] = s end\n"
  "for i = 1, 300 do files[i]:write('y') end\n"
  "p('mixed write', s:seek('end') - n0, own:seek('end'))\n"
  "for i = 1, 300 do files[i]:flush() end\n"
  "own:close()\n"
  "local cnt = 0\n"
  "s:seek('set', 0)\n"
  "for _ = 1, 300 do if s:read(1) then cnt = cnt + 1 end end\n"
  "p('hot read', cnt)\n"
  "p('close', io.close(s), nclose())\n"
  "p('closed', io.type(s), tostring(s), e(s.write, s, 'z'))\n"
  "p('close again', e(io.close, s))\n"
  "p('closed lines', e(s.lines, s))\n"
  "do local c <close> = mk() c:write('q') end\n"
  "p('tbc close', nclose())\n"
  "local w = mk()\n"
  "w:close()\n"
  "p('method close', nclose(), io.type(w))\n"
  "local g = mk()\n"
  "g = nil collectgarbage() collectgarbage()\n"
  "p('gc close', nclose())\n";

static int run(lua_State *L, int jitoff)
{
  lua_settop(L, 0);
  if (luaL_loadbuffer(L, chunk, sizeof(chunk) - 1, "=lstream") != LUA_OK) {
    printf("load error: %s\n", lua_tostring(L, -1));
    return 1;
  }
  if (jitoff) {  /* JIT builds only; PUC has no 'jit' global */
    lua_getglobal(L, "jit");
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, "off");
      lua_call(L, 0, 0);
    }
    lua_pop(L, 1);
  }
  lua_pushcfunction(L, mkstream);
  lua_pushcfunction(L, getcloses);
  if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
    printf("error: %s\n", lua_tostring(L, -1));
    return 1;
  }
  return 0;
}

int main(void)
{
  int i, bad = 0;
  for (i = 0; i < 2; i++) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    closes = 0;
    printf("-- run %d\n", i);
    bad |= run(L, i);
    lua_close(L);
    printf("closes after lua_close %d\n", closes);
  }
  fflush(stdout);
  return bad;
}
