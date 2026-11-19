/*
** udfinal.c -- lua_close must not register finalizers installed while it runs.
** Built twice: against libluajit.a and against the PUC 5.4.9 reference, which
** is the oracle. PUC 5.4.9 luaC_checkfinalizer returns early when GCSTPCLS is
** set, so a userdata created (or given a __gc metatable) inside a finalizer of
** lua_close is freed without a second __gc call. Both sides must print the same
** counts and exit 0; the test is run under a timeout, so a lua_close that keeps
** finalizing is a failure, not a hang.
**
** What the finalizer does:
**  - create a new userdata and give it the same __gc metatable (the object
**    must not be finalized during this close);
**  - give a pre-existing, reachable userdata that metatable (PUC registers
**    nothing while closing, so it must not be finalized either).
*/
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static int calls;          /* first object's __gc calls */
static int extra_calls;    /* the new userdata's __gc calls */
static int attached_calls; /* reachable userdata that got __gc during close */

static int gc_create(lua_State *L)
{
  /* Registers itself under the same metatable, and gives the reachable
  ** userdata a __gc while the state is closing. */
  calls++;
  lua_getfield(L, LUA_REGISTRYINDEX, "udfin.extra_mt");
  lua_newuserdatauv(L, 4, 0);   /* a new finalizable userdata */
  lua_pushvalue(L, -2);
  lua_setmetatable(L, -2);
  lua_pop(L, 2);                /* drop both: garbage, collectable */
  lua_getfield(L, LUA_REGISTRYINDEX, "udfin.keep");
  if (!lua_isnil(L, -1)) {
    lua_getfield(L, LUA_REGISTRYINDEX, "udfin.attached_mt");
    lua_setmetatable(L, -2);                        /* register __gc now */
  }
  lua_pop(L, 1);
  return 0;
}

static int gc_extra(lua_State *L)
{
  extra_calls++;
  return 0;
}

static int gc_attached(lua_State *L)
{
  attached_calls++;
  return 0;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);

  /* Metatable 1: __gc = gc_create, also used for the new userdata. */
  lua_newtable(L);
  lua_pushcfunction(L, gc_create);
  lua_setfield(L, -2, "__gc");
  lua_setfield(L, LUA_REGISTRYINDEX, "udfin.mt");

  /* Metatable 2 (__gc = gc_extra): given to every userdata the finalizer
  ** creates, so a second call shows up as extra_calls. */
  lua_newtable(L);
  lua_pushcfunction(L, gc_extra);
  lua_setfield(L, -2, "__gc");
  lua_setfield(L, LUA_REGISTRYINDEX, "udfin.extra_mt");

  /* Metatable 3: __gc = gc_attached, for the pre-existing reachable userdata. */
  lua_newtable(L);
  lua_pushcfunction(L, gc_attached);
  lua_setfield(L, -2, "__gc");
  lua_setfield(L, LUA_REGISTRYINDEX, "udfin.attached_mt");

  /* The reachable userdata: alive across the close through the registry. */
  lua_newuserdatauv(L, 4, 0);
  lua_setfield(L, LUA_REGISTRYINDEX, "udfin.keep");

  /* The collectable one: gets udfin.mt, then loses its only reference. */
  lua_newuserdatauv(L, 4, 0);
  lua_getfield(L, LUA_REGISTRYINDEX, "udfin.mt");
  lua_setmetatable(L, -2);
  lua_pop(L, 1);

  lua_close(L);  /* must return; the counter below shows what ran */

  printf("udfinal: first=%d extra=%d attached=%d\n",
         calls, extra_calls, attached_calls);
  /* PUC 5.4.9: exactly one __gc for the collectable userdata, nothing for
  ** the objects that got __gc while closing. */
  if (calls != 1 || extra_calls != 0 || attached_calls != 0) {
    printf("FAIL udfinal: expected first=1 extra=0 attached=0\n");
    return 1;
  }
  printf("ok   udfinal: nothing registered during lua_close\n");
  return 0;
}
