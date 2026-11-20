/*
** ccallbound.c -- every call from C into the VM counts toward the C-call
** bound (PUC ldo.c ccall / luaE_checkcstack, LUAI_MAXCCALLS = 200).
** Built twice: against libluajit.a and against the PUC 5.4.9 reference, which
** is the oracle; tests/capi/run.sh compares the two outputs. A C function
** that calls back into Lua (or into itself through lua_call, a metamethod or
** a __close handler) recursively must end in a recoverable "C stack overflow"
** at PUC's depth, and the count must be back where it was afterwards.
** Uses the Lua 5.4 API only.
*/
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static int count;

static const char *kind(lua_State *L, int idx)
{
  const char *s = lua_tostring(L, idx);
  if (s == NULL) return "(no message)";
  if (strstr(s, "C stack overflow")) return "C stack overflow";
  if (strstr(s, "error in error handling")) return "errerr";
  if (strstr(s, "stack overflow")) return "stack overflow";
  return s;
}

/* C -> Lua -> C: calls the Lua function "luafn", which calls this again. */
static int c_lua(lua_State *L)
{
  count++;
  lua_getglobal(L, "luafn");
  lua_call(L, 0, 0);
  return 0;
}

/* C -> C through lua_call. */
static int c_self(lua_State *L)
{
  count++;
  lua_pushcfunction(L, c_self);
  lua_call(L, 0, 0);
  return 0;
}

/* C -> C through lua_pcall: every level catches the error of the one below
** and returns normally. With a message handler when use_handler is set. */
static int use_handler, reported;
static int handler_calls;
static int c_handler(lua_State *L)
{
  handler_calls++;
  lua_pushfstring(L, "H:%s", kind(L, 1));
  return 1;
}

static int c_pself(lua_State *L)
{
  int status;
  count++;
  if (use_handler) lua_pushcfunction(L, c_handler);
  lua_pushcfunction(L, c_pself);
  status = lua_pcall(L, 0, 0, use_handler ? -2 : 0);
  if (status != LUA_OK && !reported) {
    reported = 1;
    printf("  innermost lua_pcall: status %d, %s, handler calls %d\n", status,
	   lua_tostring(L, -1), handler_calls);
  }
  return 0;
}

/* A to-be-closed value per level; c_closed counts the handler calls. */
static int closed;
static int c_closed(lua_State *L)
{
  (void)L;
  closed++;
  return 0;
}

static int c_tbc_self(lua_State *L)
{
  count++;
  lua_getfield(L, LUA_REGISTRYINDEX, "ccb.counted");
  lua_toclose(L, -1);
  lua_pushcfunction(L, c_tbc_self);
  lua_call(L, 0, 0);
  return 0;
}

static int c_tbc_pself(lua_State *L)
{
  count++;
  lua_getfield(L, LUA_REGISTRYINDEX, "ccb.counted");
  lua_toclose(L, -1);
  lua_pushcfunction(L, c_tbc_pself);
  if (lua_pcall(L, 0, 0, 0) != LUA_OK) lua_pop(L, 1);
  return 0;
}

/* __index metamethod called from lua_getfield, which indexes again. */
static int c_index(lua_State *L)
{
  count++;
  lua_getfield(L, 1, "x");
  return 1;
}

/* __close handler called from lua_closeslot, which declares and closes
** another to-be-closed value. */
static int c_close(lua_State *L)
{
  count++;
  lua_getfield(L, LUA_REGISTRYINDEX, "ccb.closable");
  lua_toclose(L, -1);
  lua_closeslot(L, -1);
  return 0;
}

/* lua_compare with __lt calling lua_compare again. */
static int c_lt(lua_State *L)
{
  count++;
  lua_pushboolean(L, lua_compare(L, 1, 2, LUA_OPLT));
  return 1;
}

static int c_error(lua_State *L)
{
  return luaL_error(L, "boom");
}

/* Calls back into a function that raises: the error unwinds through this
** frame's lua_call. */
static int c_callerr(lua_State *L)
{
  lua_pushcfunction(L, c_error);
  lua_call(L, 0, 0);
  return 0;
}

static void report(lua_State *L, const char *name, int status)
{
  printf("%s: status %d, %s, count %d\n", name, status,
	 status == LUA_OK ? "-" : kind(L, -1), count);
  lua_settop(L, 0);
}

static int depth(lua_State *L)
{
  int status;
  count = 0;
  lua_pushcfunction(L, c_self);
  status = lua_pcall(L, 0, 0, 0);
  lua_settop(L, 0);
  return status == LUA_ERRRUN ? count : -1;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  lua_State *co;
  int status, d0, i, nres;
  luaL_openlibs(L);

  lua_pushcfunction(L, c_lua);
  lua_setglobal(L, "cfn");
  if (luaL_dostring(L, "function luafn() return cfn() end")) return 2;

  count = 0;
  lua_pushcfunction(L, c_lua);
  report(L, "c-lua", lua_pcall(L, 0, 0, 0));

  count = 0;
  lua_getglobal(L, "luafn");
  report(L, "lua-c", lua_pcall(L, 0, 0, 0));

  count = 0;
  lua_pushcfunction(L, c_self);
  report(L, "c-c", lua_pcall(L, 0, 0, 0));

  count = 0;
  lua_pushcfunction(L, c_pself);
  report(L, "c-pcall-c", lua_pcall(L, 0, 0, 0));

  count = 0; use_handler = 1; reported = 0; handler_calls = 0;
  lua_pushcfunction(L, c_pself);
  report(L, "c-pcall-handler-c", lua_pcall(L, 0, 0, 0));
  use_handler = 0;

  /* to-be-closed values: all handlers run, after the overflow as well */
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, c_closed);
  lua_setfield(L, -2, "__close");
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "ccb.counted");
  count = 0; closed = 0;
  lua_pushcfunction(L, c_tbc_self);
  status = lua_pcall(L, 0, 0, 0);
  printf("tbc-unwind: status %d, %s, count %d, closed %d\n", status,
	 kind(L, -1), count, closed);
  lua_settop(L, 0);
  count = 0; closed = 0;
  lua_pushcfunction(L, c_tbc_pself);
  status = lua_pcall(L, 0, 0, 0);
  printf("tbc-pcall: status %d, count %d, closed %d\n", status, count, closed);
  lua_settop(L, 0);

  count = 0;
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, c_index);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_pushcfunction(L, c_index);
  lua_insert(L, -2);
  report(L, "getfield-index", lua_pcall(L, 1, 1, 0));

  count = 0;
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, c_close);
  lua_setfield(L, -2, "__close");
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "ccb.closable");
  lua_pushcfunction(L, c_close);
  report(L, "closeslot-close", lua_pcall(L, 0, 0, 0));

  count = 0;
  lua_pushcfunction(L, c_lt);
  lua_newtable(L);
  lua_newtable(L);
  lua_pushcfunction(L, c_lt);
  lua_setfield(L, -2, "__lt");
  lua_setmetatable(L, -2);
  lua_pushvalue(L, -1);
  report(L, "compare-lt", lua_pcall(L, 2, 1, 0));

  /* message handler */
  count = 0; handler_calls = 0;
  lua_pushcfunction(L, c_handler);
  lua_pushcfunction(L, c_self);
  status = lua_pcall(L, 0, 0, 1);
  printf("handler: status %d, %s, count %d, handler calls %d\n", status,
	 lua_tostring(L, -1), count, handler_calls);
  lua_settop(L, 0);

  /* in a coroutine: lua_resume takes one level */
  count = 0;
  co = lua_newthread(L);
  lua_pushcfunction(co, c_self);
  status = lua_resume(co, L, 0, &nres);
  printf("resume: status %d, %s, count %d\n", status, kind(co, -1), count);
  lua_settop(L, 0);

  /* the count is exact afterwards */
  d0 = depth(L);
  printf("depth: %d\n", d0);
  for (i = 0; i < 300; i++) {
    lua_pushcfunction(L, c_callerr);
    lua_pcall(L, 0, 0, 0);
    lua_settop(L, 0);
  }
  printf("after-error: %d\n", depth(L) - d0);
  for (i = 0; i < 300; i++) {
    lua_pushcfunction(L, c_handler);
    lua_pushcfunction(L, c_callerr);
    lua_pcall(L, 0, 0, 1);
    lua_settop(L, 0);
  }
  printf("after-error-handler: %d\n", depth(L) - d0);
  for (i = 0; i < 300; i++) {
    co = lua_newthread(L);
    lua_pushcfunction(co, c_callerr);
    lua_resume(co, L, 0, &nres);
    lua_settop(L, 0);
  }
  printf("after-error-coroutine: %d\n", depth(L) - d0);
  for (i = 0; i < 5; i++) depth(L);
  printf("after-overflow: %d\n", depth(L) - d0);
  /* The checks above start from a lua_pcall, which restores the count it
  ** saved. A pcall from Lua counts relative to what it finds, so a level an
  ** unwinding leaves behind shows as a lower depth here. */
  lua_pushcfunction(L, c_callerr);
  lua_setglobal(L, "callerr");
  lua_pushcfunction(L, c_self);
  lua_setglobal(L, "cself");
  if (luaL_dostring(L,
	"local function depth() local n = 0\n"
	"  local function rec() n = n + 1; pcall(rec) end\n"
	"  pcall(rec); return n end\n"
	"local d0 = depth()\n"
	"for i = 1, 300 do pcall(callerr) end\n"
	"local d1 = depth()\n"
	"for i = 1, 5 do pcall(cself) end\n"
	"local d2 = depth()\n"
	"for i = 1, 300 do xpcall(callerr, function(m) return m end) end\n"
	"return d0, d1 - d0, d2 - d0, depth() - d0")) {
    printf("lua probe: %s\n", lua_tostring(L, -1));
    return 4;
  }
  printf("lua-depth: %d, after-error %d, after-overflow %d, after-xpcall %d\n",
	 (int)lua_tointeger(L, -4), (int)lua_tointeger(L, -3),
	 (int)lua_tointeger(L, -2), (int)lua_tointeger(L, -1));
  lua_settop(L, 0);
  if (luaL_dostring(L, "return 1 + 1") || lua_tointeger(L, -1) != 2) return 3;
  printf("fine\n");
  lua_close(L);
  return 0;
}
