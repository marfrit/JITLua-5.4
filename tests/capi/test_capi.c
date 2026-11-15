/* C API conformance tests for the Lua 5.4 surface (MISSION P1.6).
** Build/run: tests/capi/run.sh   (links against the freshly built LuaJIT)
** Prints one line per check; exits non-zero on any failure.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int failures = 0, checks = 0;

static void ok(int cond, const char *name)
{
  checks++;
  if (!cond) { failures++; printf("FAIL %s\n", name); }
  else printf("ok   %s\n", name);
}

static lua_State *newL(void)
{
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  return L;
}

static void test_absindex(void)
{
  lua_State *L = newL();
  lua_pushinteger(L, 10); lua_pushinteger(L, 20); lua_pushinteger(L, 30);
  ok(lua_absindex(L, -1) == 3, "absindex(-1)");
  ok(lua_absindex(L, -3) == 1, "absindex(-3)");
  ok(lua_absindex(L, 2) == 2, "absindex(2)");
  ok(lua_absindex(L, LUA_REGISTRYINDEX) == LUA_REGISTRYINDEX, "absindex(registry)");
  lua_close(L);
}

static void test_getseti(void)
{
  lua_State *L = newL();
  luaL_dostring(L, "t = setmetatable({}, {__index = function(_, k) return k * 2 end,"
		   " __newindex = function(tb, k, v) rawset(tb, k, v + 1) end})");
  lua_getglobal(L, "t");
  lua_geti(L, -1, 7);
  ok(lua_tointeger(L, -1) == 14, "geti honors __index");
  lua_pop(L, 1);
  lua_pushinteger(L, 5);
  lua_seti(L, -2, 3);
  lua_geti(L, -1, 3);
  ok(lua_tointeger(L, -1) == 6, "seti honors __newindex");
  lua_pop(L, 2);
  /* plain table */
  luaL_dostring(L, "p = {}");
  lua_getglobal(L, "p");
  lua_pushinteger(L, 42); lua_seti(L, -2, 1);
  lua_geti(L, -1, 1);
  ok(lua_tointeger(L, -1) == 42, "geti/seti roundtrip");
  lua_close(L);
}

static void test_len(void)
{
  lua_State *L = newL();
  lua_pushstring(L, "hello");
  lua_len(L, -1);
  ok(lua_tointeger(L, -1) == 5, "lua_len(string)");
  lua_pop(L, 2);
  luaL_dostring(L, "tl = setmetatable({}, {__len = function() return 2.5 end})");
  lua_getglobal(L, "tl");
  lua_len(L, -1);
  ok(lua_tonumber(L, -1) == 2.5, "lua_len honors __len (any value)");
  lua_pop(L, 2);
  luaL_dostring(L, "tt = {1,2,3}");
  lua_getglobal(L, "tt");
  ok(luaL_len(L, -1) == 3, "luaL_len(table)");
  lua_pop(L, 1);
  lua_close(L);
}

static void test_compare(void)
{
  lua_State *L = newL();
  lua_pushinteger(L, 1); lua_pushnumber(L, 1.0);
  ok(lua_compare(L, -2, -1, LUA_OPEQ) == 1, "compare EQ int/float");
  ok(lua_compare(L, -2, -1, LUA_OPLT) == 0, "compare LT int/float");
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 1, "compare LE int/float");
  lua_pop(L, 2);
  lua_pushnumber(L, 1.5); lua_pushinteger(L, 2);
  ok(lua_compare(L, -2, -1, LUA_OPLT) == 1, "compare LT 1.5<2");
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 1, "compare LE 1.5<=2");
  lua_pop(L, 2);
  luaL_dostring(L, "cm = setmetatable({}, {__lt = function() return true end,"
		   " __le = function() return false end})");
  lua_getglobal(L, "cm"); lua_pushvalue(L, -1);
  ok(lua_compare(L, -2, -1, LUA_OPLT) == 1, "compare LT __lt");
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 0, "compare LE __le");
  lua_close(L);
}

static void test_stringtonumber(void)
{
  lua_State *L = newL();
  ok(lua_stringtonumber(L, "123") == 4 && lua_tointeger(L, -1) == 123, "stringtonumber int");
  lua_pop(L, 1);
  ok(lua_stringtonumber(L, "0x10") == 5 && lua_tointeger(L, -1) == 16, "stringtonumber hex");
  lua_pop(L, 1);
  ok(lua_stringtonumber(L, "  12  ") != 0 && lua_tointeger(L, -1) == 12, "stringtonumber spaces");
  lua_pop(L, 1);
  ok(lua_stringtonumber(L, "12abc") == 0, "stringtonumber rejects trailing garbage");
  ok(lua_stringtonumber(L, "1e2") != 0 && lua_tonumber(L, -1) == 100.0, "stringtonumber float");
  lua_pop(L, 1);
  ok(lua_stringtonumber(L, "inf") == 0, "stringtonumber rejects inf");
  ok(lua_stringtonumber(L, "nan") == 0, "stringtonumber rejects nan");
  lua_close(L);
}

static void test_getsubtable(void)
{
  lua_State *L = newL();
  luaL_dostring(L, "root = {}");
  lua_getglobal(L, "root");
  ok(luaL_getsubtable(L, -1, "sub") == 0 && lua_istable(L, -1), "getsubtable creates");
  lua_pop(L, 1);
  ok(luaL_getsubtable(L, -1, "sub") == 1, "getsubtable finds existing");
  lua_close(L);
}

static void test_isinteger(void)
{
  lua_State *L = newL();
  lua_pushinteger(L, 3);
  ok(lua_isinteger(L, -1) == 1, "isinteger(pushinteger)");
  lua_pop(L, 1);
  lua_pushnumber(L, 3.0);
  ok(lua_isinteger(L, -1) == 0, "isinteger(3.0) is false");
  lua_pop(L, 1);
  lua_pushstring(L, "3");
  ok(lua_isinteger(L, -1) == 0, "isinteger(string) is false");
  lua_close(L);
}

static void test_rotate(void)
{
  lua_State *L = newL();
  /* [10,20,30] rotate(1,1) -> [30,10,20] */
  lua_pushinteger(L, 10); lua_pushinteger(L, 20); lua_pushinteger(L, 30);
  lua_rotate(L, 1, 1);
  ok(lua_tointeger(L, 1) == 30 && lua_tointeger(L, 2) == 10 &&
     lua_tointeger(L, 3) == 20, "rotate(1,1)");
  lua_settop(L, 0);
  /* rotate(1,-1) -> [20,30,10] */
  lua_pushinteger(L, 10); lua_pushinteger(L, 20); lua_pushinteger(L, 30);
  lua_rotate(L, 1, -1);
  ok(lua_tointeger(L, 1) == 20 && lua_tointeger(L, 2) == 30 &&
     lua_tointeger(L, 3) == 10, "rotate(1,-1)");
  lua_settop(L, 0);
  /* sub-range: [10,20,30,40] rotate(2,1) -> [10,40,20,30] */
  lua_pushinteger(L, 10); lua_pushinteger(L, 20);
  lua_pushinteger(L, 30); lua_pushinteger(L, 40);
  lua_rotate(L, 2, 1);
  ok(lua_tointeger(L, 1) == 10 && lua_tointeger(L, 2) == 40 &&
     lua_tointeger(L, 3) == 20 && lua_tointeger(L, 4) == 30, "rotate(2,1)");
  lua_settop(L, 0);
  /* rotate by 0 and by count are identities */
  lua_pushinteger(L, 1); lua_pushinteger(L, 2);
  lua_rotate(L, 1, 0);
  ok(lua_tointeger(L, 1) == 1 && lua_tointeger(L, 2) == 2, "rotate(1,0)");
  lua_rotate(L, 1, 2);
  ok(lua_tointeger(L, 1) == 1 && lua_tointeger(L, 2) == 2, "rotate(1,count)");
  lua_close(L);
}

int main(void)
{
  test_absindex(); test_getseti(); test_len(); test_compare();
  test_stringtonumber(); test_getsubtable(); test_isinteger(); test_rotate();
  printf("== capi: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
