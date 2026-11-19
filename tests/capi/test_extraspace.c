/* C API conformance test for lua_getextraspace (PUC Lua 5.4 semantics).
**
** Build/run: tests/capi/run.sh (it also builds this file).
** Prints one line per check; exits non-zero on any failure.
**
** PUC contract (lua.h LUA_EXTRASPACE, lstate.c lua_newthread):
**   - every thread owns LUA_EXTRASPACE bytes;
**   - lua_getextraspace(L) points at them and stays valid for the thread;
**   - a new thread starts with a COPY of the MAIN thread's area;
**   - the area is raw memory: the GC does not touch it, the thread frees it.
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

/* Fetch a thread stored in a global. The global anchors it, so a GC cannot
** collect it while we still hold a lua_State pointer. */
static lua_State *getthread(lua_State *L, const char *name)
{
  lua_State *T;
  lua_getglobal(L, name);
  T = lua_tothread(L, -1);
  lua_pop(L, 1);
  return T;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);

  /* --- the main thread: non-NULL, stable, writable ---------------------- */
  {
    void *m1 = lua_getextraspace(L);
    void *m2 = lua_getextraspace(L);
    ok(m1 != NULL, "main thread has an extraspace pointer");
    ok(m1 == m2, "main thread pointer is stable across calls");
    ok(LUA_EXTRASPACE >= sizeof(void *), "LUA_EXTRASPACE is at least pointer sized");
    memset(m1, 0x5a, LUA_EXTRASPACE);
    ok(((unsigned char *)m1)[0] == 0x5a &&
       ((unsigned char *)m1)[LUA_EXTRASPACE - 1] == 0x5a,
       "main extraspace is writable and readable");
  }

  /* --- a thread created from C: own area, copied from main -------------- */
  {
    void *m1 = lua_getextraspace(L);
    lua_State *T = lua_newthread(L);
    void *te = lua_getextraspace(T);
    ok(te != NULL, "new thread has an extraspace pointer");
    ok(te != m1, "new thread area is distinct from the main area");
    ok(memcmp(te, m1, LUA_EXTRASPACE) == 0,
       "new thread area copies the main area at creation");
    memset(te, 0xa5, LUA_EXTRASPACE);
    ok(((unsigned char *)m1)[0] == 0x5a,
       "writing the thread area leaves the main area alone");
    memset(m1, 0x3c, LUA_EXTRASPACE);
    ok(((unsigned char *)te)[0] == 0xa5,
       "writing the main area leaves the copied thread area alone");
    lua_settop(L, 0);
  }

  /* --- a coroutine copies the MAIN area, not its parent's --------------- */
  {
    lua_State *co, *inner;
    void *m1 = lua_getextraspace(L);
    /* main is 0x3c from the block above; co copies that at create time. */
    luaL_dostring(L, "co = coroutine.create(function() "
		     "  inner = coroutine.create(function() end) "
		     "end)");
    lua_settop(L, 0);
    co = getthread(L, "co");
    ok(co != NULL && memcmp(lua_getextraspace(co), m1, LUA_EXTRASPACE) == 0,
       "coroutine copies the main area at creation");
    /* Change main AFTER co exists; resuming co creates inner, which must
    ** see the new main bytes, not co's stale copy. */
    memset(m1, 0x77, LUA_EXTRASPACE);
    luaL_dostring(L, "assert(coroutine.resume(co))");
    lua_settop(L, 0);
    inner = getthread(L, "inner");
    ok(inner != NULL &&
       memcmp(lua_getextraspace(inner), m1, LUA_EXTRASPACE) == 0,
       "a nested coroutine copies the main area, not its parent's");
  }

  /* --- stability across GC and resume/yield ----------------------------- */
  {
    lua_State *co2;
    void *p;
    void *mp = lua_getextraspace(L);
    luaL_dostring(L, "co2 = coroutine.create(function() "
		     "  coroutine.yield('y'); return 'r' end)");
    lua_settop(L, 0);
    co2 = getthread(L, "co2");
    ok(co2 != NULL, "coroutine thread is reachable");
    p = lua_getextraspace(co2);
    memset(p, 0x11, LUA_EXTRASPACE);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    ok(lua_getextraspace(co2) == p, "thread pointer stable across a full GC");
    ok(((unsigned char *)p)[0] == 0x11, "thread area content survives a full GC");
    ok(lua_getextraspace(L) == mp, "main pointer stable across a full GC");
    luaL_dostring(L, "assert(coroutine.resume(co2))");
    lua_settop(L, 0);
    ok(lua_getextraspace(co2) == p, "thread pointer stable across a yield");
    ok(((unsigned char *)p)[0] == 0x11, "thread area content survives a yield");
    luaL_dostring(L, "assert(coroutine.resume(co2))");
    lua_settop(L, 0);
    ok(lua_getextraspace(co2) == p, "thread pointer stable across resume/completion");
  }

  lua_close(L);
  printf("== extraspace: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
