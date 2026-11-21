/*
** ffilateio.c -- the io library is opened after a trace was recorded.
** A state without the io library has no file metatable, so a userdata
** passed to the FFI is its payload address and a loop doing that is
** compiled. Then the io library is opened and a C module makes a file
** handle (a luaL_Stream block with the LUA_FILEHANDLE metatable): the
** interpreter converts it to its FILE pointer from then on, and the trace
** recorded before must not convert it to the block address. The chunk
** checks itself and the program exits non-zero on a mismatch; it runs with
** the JIT on and off.
*/
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static int stream_close(lua_State *L)
{
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
  return luaL_fileresult(L, fclose(p->f) == 0, NULL);
}

static int mkstream(lua_State *L)
{
  luaL_Stream *p = (luaL_Stream *)lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
  p->closef = NULL;
  luaL_setmetatable(L, LUA_FILEHANDLE);
  p->f = tmpfile();
  if (p->f == NULL) return luaL_fileresult(L, 0, "tmpfile");
  p->closef = &stream_close;
  return 1;
}

/* A plain userdata of the same size, and its payload address. */
static int mkplain(lua_State *L)
{
  void *p = lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
  memset(p, 0, sizeof(luaL_Stream));
  lua_pushlightuserdata(L, p);
  return 2;
}

static int openio(lua_State *L)
{
  luaL_requiref(L, LUA_IOLIBNAME, luaopen_io, 1);
  return 0;
}

static const char chunk[] =
  "local mkplain, mkstream, openio = ...\n"
  "assert(io == nil)\n"
  "local vp = ffi.typeof('void *')\n"
  "local function count(uds, want) local c = 0\n"
  "  for i = 1, #uds do if ffi.cast(vp, uds[i]) == want then c = c + 1 end end\n"
  "  return c end\n"
  "local pl, addr = mkplain()\n"
  "local pa = ffi.cast(vp, addr)\n"
  "local uds = {}\n"
  "for i = 1, 300 do uds[i] = pl end\n"
  "assert(count(uds, pa) == 300, 'plain userdata, no io library')\n"
  "openio()\n"
  "local s = mkstream()\n"
  "local fp = ffi.cast(vp, s)\n"
  "assert(fp ~= nil and fp ~= pa and io.type(s) == 'file')\n"
  "for i = 151, 300 do uds[i] = s end\n"
  "local n, m = count(uds, pa), count(uds, fp)\n"
  "assert(n == 150 and m == 150, 'stream after the io library was opened: ' .. n .. ' ' .. m)\n"
  "s:close()\n"
  "assert(ffi.cast(vp, s) == nil, 'closed stream')\n"
  "print('ok')\n";

static int run(lua_State *L, int jitoff)
{
  luaL_requiref(L, LUA_GNAME, luaopen_base, 1);
  lua_pushcfunction(L, luaopen_jit);  /* Registers the global itself. */
  lua_call(L, 0, 0);
  luaL_requiref(L, LUA_FFILIBNAME, luaopen_ffi, 1);
  lua_settop(L, 0);
  if (luaL_loadbuffer(L, chunk, sizeof(chunk) - 1, "=ffilateio") != LUA_OK) {
    printf("load error: %s\n", lua_tostring(L, -1));
    return 1;
  }
  if (jitoff) {
    lua_getglobal(L, "jit");
    lua_getfield(L, -1, "off");
    lua_call(L, 0, 0);
    lua_pop(L, 1);
  }
  lua_pushcfunction(L, mkplain);
  lua_pushcfunction(L, mkstream);
  lua_pushcfunction(L, openio);
  if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
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
    printf("-- run %d\n", i);
    fflush(stdout);
    bad |= run(L, i);
    lua_close(L);
  }
  fflush(stdout);
  return bad;
}
