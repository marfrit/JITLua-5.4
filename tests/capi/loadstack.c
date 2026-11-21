/* The loaders leave exactly one value on the stack: the function, or the
** error message. Same source against JITLua-5.4 and PUC 5.4.9; the outputs
** must be identical (tests/capi/run.sh). */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static void show(lua_State *T, const char *tag, int st)
{
  int i, top = lua_gettop(T);
  printf("%-28s st=%d top=%d:", tag, st, top);
  for (i = 1; i <= top; i++) printf(" %s", luaL_typename(T, i));
  printf("\n");
  lua_settop(T, 0);
}

static int yielder(lua_State *L) { return lua_yield(L, lua_gettop(L)); }

static const char *nested =
  "local function a() return function() return function() end end end\n"
  "local t = {function() end, function() end, 1.5, 2.5, 'x'}\n"
  "return a, t";

int main(void)
{
  lua_State *L = luaL_newstate();
  lua_State *co;
  int st, nres = -1, i;
  st = luaL_loadbuffer(L, "return 7", 8, "=x"); show(L, "bare loadbuffer", st);
  luaL_openlibs(L);
  st = luaL_loadstring(L, "return 7"); show(L, "loadstring", st);
  st = luaL_loadbufferx(L, "return 7", 8, "=x", "t"); show(L, "loadbufferx t", st);
  st = luaL_loadbufferx(L, "return 7", 8, "=x", "b"); show(L, "loadbufferx b (refused)", st);
  st = luaL_loadstring(L, nested); show(L, "loadstring nested", st);
  st = luaL_loadstring(L, "return 7 +"); show(L, "loadstring syntax error", st);
  st = luaL_loadstring(L, "x = = 1 function f() end"); show(L, "loadstring syntax error 2", st);
  st = luaL_loadbufferx(L, nested, strlen(nested), "=y", NULL); show(L, "loadbufferx nested", st);
  st = luaL_loadfile(L, "tests/capi/no-such-file.lua"); show(L, "loadfile missing", st);
  st = luaL_dostring(L, "return 1, 2"); show(L, "dostring", st);
  st = luaL_dostring(L, nested); show(L, "dostring nested", st);
  st = luaL_dostring(L, "error('e')"); show(L, "dostring error", st);
  lua_pushinteger(L, 1); lua_pushinteger(L, 2);
  st = luaL_loadstring(L, nested);
  printf("above two values: st=%d top=%d %s %s %s\n", st, lua_gettop(L),
	 luaL_typename(L, 1), luaL_typename(L, 2), luaL_typename(L, 3));
  lua_settop(L, 0);
  for (i = 0; i < 20000; i++) {  /* No slot may stay behind per call. */
    if (luaL_loadstring(L, nested) != LUA_OK) break;
    lua_pop(L, 1);
  }
  printf("20000 loads: i=%d top=%d\n", i, lua_gettop(L));
  co = lua_newthread(L);
  st = luaL_loadstring(co, "local y = ... local a, b = y(1, 2) return a + b");
  lua_pushcfunction(co, yielder);
  st = lua_resume(co, L, 1, &nres);
  printf("resume 1: st=%d nres=%d top=%d\n", st, nres, lua_gettop(co));
  lua_pop(co, nres);
  lua_pushinteger(co, 10); lua_pushinteger(co, 20);
  st = lua_resume(co, L, 2, &nres);
  printf("resume 2: st=%d nres=%d top=%d value=%d\n", st, nres, lua_gettop(co),
	 (int)lua_tointeger(co, -1));
  lua_close(L);
  return 0;
}
