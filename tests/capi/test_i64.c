/* Step-1 conformance test for the boxed interned int64 (ADR-001b).
** Opaque declarations only, so the test never disagrees with the library's
** TValue layout.
**
** Build/run: tests/capi/run.sh (it also builds this file).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

typedef struct lua_State lua_State;
extern void *lj_i64_box(lua_State *L, long long v);

static int failures = 0, checks = 0;
static void ok(int cond, const char *name)
{
  checks++;
  if (!cond) { failures++; printf("FAIL %s\n", name); }
  else printf("ok   %s\n", name);
}

int main(void)
{
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);

  void *a = lj_i64_box(L, 9007199254740993LL);            /* > 2^53 */
  void *b = lj_i64_box(L, 9007199254740993LL);
  void *c = lj_i64_box(L, 9007199254740994LL);
  void *d = lj_i64_box(L, -9223372036854775807LL - 1);    /* INT64_MIN */
  void *e = lj_i64_box(L, 9223372036854775807LL);         /* INT64_MAX */
  ok(a != NULL, "box returns an object");
  ok(a == b, "equal values share one box (interned)");
  ok(a != c, "different values are different boxes");
  ok(d != e, "INT64_MIN and INT64_MAX are distinct");
  ok(d != a, "negative differs from the >2^53 value");

  /* A box must survive a full GC while the intern table holds it. */
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
  ok(lj_i64_box(L, 9007199254740993LL) == a,
     "interned box survives collection as the same object");

  {
    int i, bad = 0;
    void *ref[16];
    for (i = 0; i < 16; i++)
      ref[i] = lj_i64_box(L, 0x7fffffff00000000LL + i);
    for (i = 0; i < 16; i++)
      if (lj_i64_box(L, 0x7fffffff00000000LL + i) != ref[i]) bad++;
    ok(bad == 0, "16 large values intern distinctly and reproducibly");
  }

  /* ADR-001b: a box must never look like userdata through the C API. */
  {
    int rc = luaL_dostring(L, "return math.maxinteger");
    ok(rc == 0 && lua_gettop(L) >= 1, "maxinteger pushed");
    if (rc == 0 && lua_gettop(L) >= 1) {
      int okv = 0;
      lua_Integer mi;
      ok(lua_type(L, -1) == LUA_TNUMBER, "lua_type(maxinteger) == LUA_TNUMBER");
      ok(lua_touserdata(L, -1) == NULL, "lua_touserdata(maxinteger) == NULL");
      ok(lua_isnumber(L, -1) == 1, "lua_isnumber(maxinteger)");
      ok(lua_isinteger(L, -1) == 1, "lua_isinteger(maxinteger)");
      mi = lua_tointegerx(L, -1, &okv);
      ok(okv == 1 && mi == (lua_Integer)9223372036854775807LL,
	 "lua_tointegerx(maxinteger) is exact");
      ok(strcmp(lua_tostring(L, -1), "9223372036854775807") == 0,
	 "lua_tostring(maxinteger) is exact");
    }
    lua_settop(L, 0);
  }

  lua_close(L);
  printf("== i64: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
