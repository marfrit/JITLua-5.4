/* PUC 5.4.9 reference for the bare-state behaviour of test_capi.c
** (test_bare_state): a state created with luaL_newstate() and no libraries
** must load and run chunks that name globals, and lua_getglobal/lua_setglobal
** must work through the C API. This is the parity check the fork's fix is
** measured against.
**
** tests/capi/run.sh compiles this against the vendored PUC 5.4.9 tree when it
** is present (ci-box.sh builds it before the C API stage). It only uses the
** standard C API, so it builds against both implementations; the JIT part of
** the bare-state test has no PUC counterpart and stays in test_capi.c.
*/
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

static int failures = 0, checks = 0;

static void ok(int cond, const char *name)
{
  checks++;
  if (!cond) { failures++; printf("FAIL %s\n", name); }
  else printf("ok   %s\n", name);
}

int main(void)
{
  lua_State *L = luaL_newstate();  /* deliberately no luaL_openlibs */
  int rc = luaL_dostring(L,
    "x = 1\n"
    "y = x + 2\n"
    "local s = 0\n"
    "for i = 1, 10 do s = s + x end\n"
    "z = s\n");
  ok(rc == LUA_OK, "PUC bare state: chunk with global read/write/loop runs");
  if (rc != LUA_OK) printf("     error: %s\n", lua_tostring(L, -1));
  lua_getglobal(L, "y");
  ok(lua_tointeger(L, -1) == 3, "PUC bare state: global written by chunk is visible");
  lua_pop(L, 1);
  lua_getglobal(L, "z");
  ok(lua_tointeger(L, -1) == 10, "PUC bare state: loop over a global yields the right value");
  lua_pop(L, 1);
  lua_pushinteger(L, 42);
  lua_setglobal(L, "answer");
  lua_getglobal(L, "answer");
  ok(lua_tointeger(L, -1) == 42, "PUC bare state: lua_setglobal/lua_getglobal round-trip");
  lua_pop(L, 1);
  lua_close(L);
  printf("== PUC bare state: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
