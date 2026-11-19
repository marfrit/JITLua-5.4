/*
** probe_549.c -- C API probes backing the DIFFERENCES.md entries that are
** only observable from C. Built twice: against libluajit.a and against the
** PUC 5.4.9 reference libs (tests/ref), which are the oracle.
**
** Observations:
**  - lua_setcstacklimit: PUC 5.4.9 (src/lstate.c:99) is a no-op returning
**    LUAI_MAXCCALLS (200, src/llimits.h:255). The same holds here
**    (src/lj_api.c:1237); the old PENDING "PUC sets a new limit" entry was
**    wrong for 5.4.9. Asserted on both builds: both must return 200.
**  - lua_getextraspace: PUC is a macro over a reserved area before
**    lua_State (src/lua.h:371, src/luaconf.h:760, LUA_EXTRASPACE defaults
**    to sizeof(void*)). This fork has no such area; the API is absent from
**    src/lua.h (PENDING entry).
**  - Note: this probe opens the standard libraries before running chunks.
**    PUC 5.4.9 runs luaL_dostring on a bare state; this fork segfaults
**    there (GGET _ENV special case before lib_base is installed) -- see
**    docs/differences-audit-2026-11.md, "new differences found".
**  - String interning: PUC does not intern long strings
**    (src/lstring.c luaS_newlstr -> fresh object per call); LuaJIT interns
**    every string (src/lj_str.c lj_str_new). Observed with lua_topointer
**    on runtime-built equal strings (FORK entry).
**
** Print-only except the two parity asserts.
*/
#include <stdio.h>
#include <stddef.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static int same_ptr(lua_State *L, const char *g1, const char *g2)
{
  lua_getglobal(L, g1);
  lua_getglobal(L, g2);
  int same = (lua_topointer(L, -1) == lua_topointer(L, -2));
  lua_pop(L, 2);
  return same;
}

int main(void)
{
  int fails = 0;
  lua_State *L = luaL_newstate();
  int lim;

  /* lua_setcstacklimit is a C-stack no-op on both sides; it does not need
  ** the libraries. Chunk execution does: open them (PUC tolerates a bare
  ** state, this fork segfaults there -- noted in the audit doc). */
  luaL_openlibs(L);

  lim = lua_setcstacklimit(L, 300);
  printf("setcstacklimit(300)=%d\n", lim);
  if (lim != 200) { printf("FAIL: expected 200\n"); fails++; }
  lim = lua_setcstacklimit(L, 0);
  printf("setcstacklimit(0)=%d\n", lim);
  if (lim != 200) { printf("FAIL: expected 200\n"); fails++; }

#ifdef lua_getextraspace
  {
    void *e = lua_getextraspace(L);
    unsigned char *p = (unsigned char *)e;  /* the area is app storage */
    p[0] = 0xAB;
    lua_State *T = lua_newthread(L);  /* created with a copy of the area */
    void *e2 = lua_getextraspace(T);
    printf("extraspace nonnull=%d threadcopy=%d size=%lu\n",
           e != NULL, ((unsigned char *)e2)[0] == 0xAB,
           (unsigned long)sizeof(void *));
    if (e == NULL) fails++;
    lua_pop(L, 1);
  }
#else
  printf("extraspace absent\n");
#endif

  luaL_dostring(L,
    "long1 = 'x' .. string.rep('a', 200)\n"
    "long2 = 'x' .. string.rep('a', 200)\n"
    "gsub1 = string.rep('a', 200):gsub('a', 'b')\n"
    "gsub2 = string.rep('a', 200):gsub('a', 'b')\n"
    "short1 = string.rep('a', 5)\n"
    "short2 = string.rep('a', 5)\n");
  printf("longstr same=%d\n", same_ptr(L, "long1", "long2"));
  printf("gsub same=%d\n", same_ptr(L, "gsub1", "gsub2"));
  printf("shortstr same=%d\n", same_ptr(L, "short1", "short2"));

  lua_close(L);
  return fails;
}
