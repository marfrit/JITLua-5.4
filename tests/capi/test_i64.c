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

/* Calls luaL_checkudata so that its error can be caught by lua_pcall. */
static int checkudata_reject(lua_State *L)
{
  luaL_checkudata(L, 1, "no_such_udata_type");
  return 0;
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

  /* The intern table is weak: a box survives a full GC only while something
  ** references it. Anchor the value on the stack (lua_pushinteger interns
  ** the same box) and check that interning still hands out that object. */
  lua_pushinteger(L, 9007199254740993LL);
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
  ok(lj_i64_box(L, 9007199254740993LL) == a,
     "interned box survives collection as the same object");
  lua_pop(L, 1);

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

  /* ADR-001b: the boxed representation is invisible through the C API for
  ** *every* integer -- inline int32, widened 47-bit and interned box -- and
  ** for both signs. */
  {
    static const lua_Integer iv[] = {
      0, 5, -7,
      2147483648LL, -2147483649LL,             /* just outside int32 */
      (lua_Integer)1 << 46, -((lua_Integer)1 << 46),  /* 47-bit edges */
      (lua_Integer)1 << 47, (lua_Integer)1 << 60,     /* boxed */
      -((lua_Integer)1 << 60) - 1,
      9223372036854775807LL, -9223372036854775807LL - 1
    };
    int k, n = (int)(sizeof(iv) / sizeof(iv[0]));
    for (k = 0; k < n; k++) {
      char what[48], name[112];
      snprintf(what, sizeof(what), "integer %lld", (long long)iv[k]);
      lua_pushinteger(L, iv[k]);
      snprintf(name, sizeof(name), "lua_type(%s) == LUA_TNUMBER", what);
      ok(lua_type(L, -1) == LUA_TNUMBER, name);
      snprintf(name, sizeof(name), "lua_isuserdata(%s) == 0", what);
      ok(lua_isuserdata(L, -1) == 0, name);
      snprintf(name, sizeof(name), "lua_touserdata(%s) == NULL", what);
      ok(lua_touserdata(L, -1) == NULL, name);
      snprintf(name, sizeof(name), "lua_topointer(%s) == NULL", what);
      ok(lua_topointer(L, -1) == NULL, name);
      snprintf(name, sizeof(name), "luaL_testudata(%s) == NULL", what);
      ok(luaL_testudata(L, -1, "no_such_udata_type") == NULL, name);
      lua_pop(L, 1);
    }
  }

  /* lua_rawlen/lua_rawequal give the same answers as for the other numbers
  ** (this fork's lua_objlen returns the length of the decimal text). */
  {
    static const struct { lua_Integer v; size_t len; } rl[] = {
      { 5, 1 }, { -7, 2 },
      { 2147483648LL, 10 }, { -2147483649LL, 11 },
      { (lua_Integer)1 << 40, 13 },
      { (lua_Integer)1 << 60, 19 },
      { -((lua_Integer)1 << 60) - 1, 20 },
      { 9223372036854775807LL, 19 },
      { -9223372036854775807LL - 1, 20 }
    };
    int k, n = (int)(sizeof(rl) / sizeof(rl[0]));
    for (k = 0; k < n; k++) {
      char name[96];
      lua_pushinteger(L, rl[k].v);
      snprintf(name, sizeof(name), "lua_rawlen(%lld) == %u",
               (long long)rl[k].v, (unsigned)rl[k].len);
      ok(lua_rawlen(L, -1) == rl[k].len, name);
      lua_pop(L, 1);
    }
  }
  lua_pushinteger(L, (lua_Integer)1 << 60);   /* same interned box */
  lua_pushinteger(L, (lua_Integer)1 << 60);
  ok(lua_rawequal(L, -2, -1) == 1, "lua_rawequal(box, same box) == 1");
  lua_pop(L, 1);
  lua_pushinteger(L, ((lua_Integer)1 << 60) + 1);
  ok(lua_rawequal(L, -2, -1) == 0, "lua_rawequal(box, other box) == 0");
  lua_pop(L, 1);
  lua_pushnumber(L, (lua_Number)((lua_Integer)1 << 60));
  ok(lua_rawequal(L, -2, -1) == 1, "lua_rawequal(box, equal float) == 1");
  lua_pop(L, 1);
  lua_newtable(L);
  ok(lua_rawequal(L, -2, -1) == 0, "lua_rawequal(box, table) == 0");
  lua_pop(L, 2);
  lua_pushinteger(L, (lua_Integer)1 << 46);   /* widened inline */
  lua_pushnumber(L, (lua_Number)((lua_Integer)1 << 46));
  ok(lua_rawequal(L, -2, -1) == 1, "lua_rawequal(widened, equal float) == 1");
  lua_pop(L, 2);
  lua_pushinteger(L, (lua_Integer)1 << 46);
  lua_newtable(L);
  ok(lua_rawequal(L, -2, -1) == 0, "lua_rawequal(widened, table) == 0");
  lua_pop(L, 2);
  lua_pushinteger(L, 5);
  lua_pushinteger(L, 5);
  ok(lua_rawequal(L, -2, -1) == 1, "lua_rawequal(inline, inline) == 1");
  lua_pop(L, 2);

  /* luaL_checkudata rejects a box instead of reading the box's payload. */
  lua_pushcfunction(L, checkudata_reject);
  lua_pushinteger(L, (lua_Integer)1 << 60);
  ok(lua_pcall(L, 1, 0, 0) != 0, "luaL_checkudata(box) raises");
  {
    const char *msg = lua_tostring(L, -1);
    ok(msg != NULL && strstr(msg, "number") != NULL,
       "luaL_checkudata(box) reports a number");
  }
  lua_settop(L, 0);

  lua_close(L);
  printf("== i64: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
