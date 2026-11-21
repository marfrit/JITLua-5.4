/*
** ffistream.c -- a file handle made by a C module converts to its FILE
** pointer in the FFI, like the io library's own handles do.
** A luaL_Stream block (lauxlib.h) made here is passed to C functions that
** take a FILE *: from the interpreter, from compiled loops, and at a call
** site that saw the library's own handles or another userdata first. A
** closed stream converts to NULL. A userdata whose metatable becomes the
** file metatable after a trace was recorded with it (registry["FILE*"]
** replaced) is a stream from then on, in that trace too; one too short for
** a luaL_Stream stays its payload address. The chunk checks itself and the program
** exits non-zero on a mismatch; it runs with the JIT on and off.
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

/* A plain userdata of the same size that is no stream: its payload address. */
static int mkplain(lua_State *L)
{
  void *p = lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
  memset(p, 0, sizeof(luaL_Stream));
  lua_pushlightuserdata(L, p);
  return 2;
}

/* A userdata too short for a luaL_Stream, and its payload address. */
static int mkshort(lua_State *L)
{
  void *p = lua_newuserdatauv(L, 1, 0);
  lua_pushlightuserdata(L, p);
  return 2;
}

static const char chunk[] =
  "local mk, mkplain, mkshort = ...\n"
  "local ffi = require('ffi')\n"
  "ffi.cdef[[typedef struct FILE FILE; int fputc(int c, FILE *f);\n"
  "  int fputs(const char *s, FILE *f); int fflush(FILE *f);]]\n"
  "local C = ffi.C\n"
  "local function content(f) f:flush() f:seek('set', 0) local s = f:read('a')\n"
  "  f:seek('end') return s end\n"
  "local s = mk()\n"
  "assert(C.fputs('one\\n', s) >= 0)\n"
  "assert(content(s) == 'one\\n', 'interpreted call')\n"
  "for i = 1, 300 do C.fputc(97 + i % 3, s) end\n"
  "assert(#content(s) == 304, 'compiled loop')\n"
  "local own = io.tmpfile()\n"
  "local files = {}\n"
  "for i = 1, 400 do files[i] = (i <= 250 or i > 350) and own or s end\n"
  "for i = 1, 400 do C.fputc(120, files[i]) end\n"
  "assert(#content(own) == 300 and #content(s) == 404, 'own handles first')\n"
  "for i = 1, 400 do files[i] = (i <= 250) and s or own end\n"
  "for i = 1, 400 do C.fputc(121, files[i]) end\n"
  "assert(#content(own) == 450 and #content(s) == 654, 'stream first')\n"
  "local pl, addr = mkplain()\n"
  "local vp = ffi.typeof('void *')\n"
  "assert(ffi.cast(vp, pl) == ffi.cast(vp, addr), 'plain userdata')\n"
  "assert(ffi.cast(vp, s) ~= ffi.cast(vp, pl))\n"
  "local fp, pa = ffi.cast(vp, s), ffi.cast(vp, addr)\n"
  "local uds, n, m = {}, 0, 0\n"
  "for i = 1, 400 do uds[i] = (i <= 250) and pl or s end\n"
  "for i = 1, 400 do local p = ffi.cast(vp, uds[i])\n"
  "  if p == pa then n = n + 1 elseif p == fp then m = m + 1 end end\n"
  "assert(n == 250 and m == 150, 'plain userdata first: ' .. n .. ' ' .. m)\n"
  "local function cnt(ud, want) local c = 0\n"
  "  for i = 1, 300 do if ffi.cast(vp, ud) == want then c = c + 1 end end\n"
  "  return c end\n"
  "local pm, pmaddr = mkplain()\n"
  "local M = {}\n"
  "debug.setmetatable(pm, M)\n"
  "assert(cnt(pm, ffi.cast(vp, pmaddr)) == 300, 'userdata with a metatable')\n"
  "local sh, shaddr = mkshort()\n"
  "debug.setmetatable(sh, M)\n"
  "local reg = debug.getregistry()\n"
  "local fmt = reg['FILE*']\n"
  "reg['FILE*'] = M\n"
  "local c1 = cnt(pm, ffi.cast(vp, nil))\n"
  "local c2 = cnt(sh, ffi.cast(vp, shaddr))\n"
  "reg['FILE*'] = fmt\n"
  "assert(c1 == 300, 'file metatable replaced after the trace: ' .. c1)\n"
  "assert(c2 == 300, 'short userdata with the file metatable: ' .. c2)\n"
  "assert(cnt(pm, ffi.cast(vp, pmaddr)) == 300, 'file metatable restored')\n"
  "s:close()\n"
  "assert(ffi.cast(vp, s) == nil, 'closed stream')\n"
  "own:close()\n"
  "print('ok')\n";

static int run(lua_State *L, int jitoff)
{
  if (luaL_loadbuffer(L, chunk, sizeof(chunk) - 1, "=ffistream") != LUA_OK) {
    printf("load error: %s\n", lua_tostring(L, -1));
    return 1;
  }
  if (jitoff) {
    lua_getglobal(L, "jit");
    lua_getfield(L, -1, "off");
    lua_call(L, 0, 0);
    lua_pop(L, 1);
  }
  lua_pushcfunction(L, mkstream);
  lua_pushcfunction(L, mkplain);
  lua_pushcfunction(L, mkshort);
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
    luaL_openlibs(L);
    printf("-- run %d\n", i);
    fflush(stdout);
    bad |= run(L, i);
    lua_close(L);
  }
  fflush(stdout);
  return bad;
}
