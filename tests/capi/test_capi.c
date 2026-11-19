/* C API conformance tests for the Lua 5.4 surface (MISSION P1.6).
** Build/run: tests/capi/run.sh   (links against the freshly built LuaJIT)
** Prints one line per check; exits non-zero on any failure.
*/
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include "lua.h"
#define LUAJIT_NUMMODE 2  /* only for the internal lj_obj.h stack-room probe */
#include "lauxlib.h"
#include "lualib.h"
#include "lj_obj.h"  /* test-only: stack room for the buffer close case */

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

/* System-allocator state: ASan can then see the Lua stack, so a stale
** TValue * that lua_closeslot/lua_settop kept across a stack move shows up as
** use-after-free in the sanitizer job. */
static void *sysalloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
  (void)ud; (void)osize;
  if (nsize == 0) { free(ptr); return NULL; }
  return realloc(ptr, nsize);
}

static lua_State *newL_sys(void)
{
  /* The system heap is only usable when it lies inside LuaJIT's GC address
  ** range (an ASan build satisfies that); otherwise fall back to the built-in
  ** allocator, where the stale-pointer check is invisible to ASan. */
  lua_State *L = lua_newstate(sysalloc, NULL);
  if (L == NULL) return newL();
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
  lua_pop(L, 1);  /* keep the table, pop the roundtrip result */
  /* int64 keys outside the inline forms: boxed exact, not a float. */
  {
    lua_Integer big = (lua_Integer)0x7fffffffffffffffLL;
  lua_Integer min = (lua_Integer)0x8000000000000000LL;
    lua_settop(L, 0); lua_getglobal(L, "p");  /* fresh stack */
    lua_pushinteger(L, big); lua_seti(L, -2, big);
    lua_geti(L, -1, big);
    ok(lua_tointeger(L, -1) == big, "geti/seti maxinteger key exact");
    ok(lua_tonumber(L, -1) == (lua_Number)big, "lua_tonumber(max box) exact");
    lua_pop(L, 1);
    lua_geti(L, -1, (lua_Integer)0x8000000000000000LL);
    ok(lua_isnil(L, -1), "geti mininteger key (absent) is nil");
    lua_pop(L, 1);
  }
  lua_close(L);
}

static void test_stream_abi(void)
{
  lua_State *L = newL();
  luaL_dostring(L, "P = os.tmpname(); f = io.open(P, 'w')");
  lua_getglobal(L, "f");
  {
    luaL_Stream *s = (luaL_Stream *)lua_touserdata(L, -1);
    ok(s != NULL && s->f != NULL && s->closef != NULL,
       "io.open handle is a luaL_Stream {f, closef}");
  }
  lua_pop(L, 1);
  luaL_dostring(L, "f:close(); os.remove(P)");
  /* 5.4 debug: library C functions have no visible upvalues. */
  ok(luaL_dostring(L, "assert(debug.getinfo(print, 'u').nups == 0)") == LUA_OK,
     "debug.getinfo(print,'u').nups == 0");
  lua_close(L);
}

static int open_capimod(lua_State *L)
{
  lua_newtable(L);
  lua_pushinteger(L, 321);
  lua_setfield(L, -2, "x");
  return 1;
}

static void test_api54_surface(void)
{
  lua_State *L = newL();
  char buf[64];
  luaL_checkversion(L);
  ok(1, "luaL_checkversion accepts this build");
  lua_pushglobaltable(L);
  ok(lua_istable(L, -1) && lua_getglobal(L, "print") == LUA_TFUNCTION,
     "lua_pushglobaltable is the global table");
  lua_pop(L, 1);
  lua_pushliteral(L, "abc");
  ok(lua_rawlen(L, -1) == 3, "lua_rawlen string");
  lua_pop(L, 1);
  luaL_dostring(L, "rt = {1,2,3}; setmetatable(rt, {__len = function() return 99 end})");
  lua_getglobal(L, "rt");
  ok(lua_rawlen(L, -1) == 3, "lua_rawlen table ignores __len");
  lua_pop(L, 1);
  /* rawgeti/rawseti with an int64 key outside int32; rawgetp/rawsetp. */
  lua_newtable(L);
  {
    lua_Integer big = (lua_Integer)0x7fffffffffffffffLL;
  lua_Integer min = (lua_Integer)0x8000000000000000LL;
    int anchor;
    lua_pushinteger(L, 7); lua_rawseti(L, -2, big);
    ok(lua_rawgeti(L, -1, big) == LUA_TNUMBER &&
       lua_tointeger(L, -1) == 7, "rawgeti/rawseti maxinteger key");
    lua_pop(L, 1);
    lua_pushinteger(L, 9); lua_rawsetp(L, -2, &anchor);
    ok(lua_rawgetp(L, -1, &anchor) == LUA_TNUMBER &&
       lua_tointeger(L, -1) == 9, "rawgetp/rawsetp lightuserdata key");
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  snprintf(buf, sizeof(buf), LUA_INTEGER_FMT, (LUAI_UACINT)(lua_Integer)-42);
  ok(strcmp(buf, "-42") == 0, "LUA_INTEGER_FMT formats lua_Integer");
  ok(lua_version(L) == (lua_Number)504, "lua_version returns 5.4 API version");
  lua_pushnil(L);
  { size_t len; const char *s = luaL_tolstring(L, -1, &len);
    ok(s != NULL && strcmp(s, "nil") == 0 && len == 3, "luaL_tolstring(nil)"); }
  lua_pop(L, 1);
  lua_pushnumber(L, 1.5);
  { size_t len; const char *s = luaL_tolstring(L, -1, &len);
    ok(s != NULL && strcmp(s, "1.5") == 0 && len == 3, "luaL_tolstring(1.5)"); }
  lua_pop(L, 1);
  luaL_requiref(L, "capimod", open_capimod, 1);
  ok(lua_getglobal(L, "capimod") == LUA_TTABLE &&
     lua_getfield(L, -1, "x") == LUA_TNUMBER &&
     lua_tointeger(L, -1) == 321, "luaL_requiref registers and sets global");
  lua_pop(L, 2);
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

static int throw_bad_uv(lua_State *L)
{
  lua_newuserdatauv(L, 4, 65535);  /* PUC: nuvalue < USHRT_MAX */
  return 0;
}

static void test_newuserdatauv(void)
{
  lua_State *L = newL();
  void *p;
  /* nuvalue 0: no user values at all. */
  p = lua_newuserdatauv(L, 8, 0);
  ok(p != NULL && lua_isuserdata(L, -1), "newuserdatauv(8,0)");
  ok(lua_getiuservalue(L, -1, 1) == LUA_TNONE && lua_isnil(L, -1),
     "newuserdatauv(0): get 1 is none/nil");
  lua_pop(L, 2);
  /* nuvalue 1 starts with a nil user value. */
  p = lua_newuserdatauv(L, 16, 1);
  ok(p != NULL && lua_isuserdata(L, -1), "newuserdatauv(16,1)");
  ok(lua_getiuservalue(L, -1, 1) == LUA_TNIL && lua_isnil(L, -1),
     "newuserdatauv(1): initial user value nil");
  lua_pop(L, 2);
  /* lua_newuserdata remains nuvalue=1. */
  p = lua_newuserdata(L, 4);
  ok(p != NULL && lua_getiuservalue(L, -1, 1) == LUA_TNIL && lua_isnil(L, -1),
     "lua_newuserdata = nuvalue 1 (nil)");
  lua_pop(L, 2);
  /* nuvalue >= USHRT_MAX is an error, not undefined behaviour. */
  lua_pushcfunction(L, throw_bad_uv);
  ok(lua_pcall(L, 0, 0, 0) != LUA_OK &&
     lua_tostring(L, -1) != NULL &&
     strstr(lua_tostring(L, -1), "invalid user value count") != NULL,
     "newuserdatauv(_,65535) errors clearly");
  lua_pop(L, 1);
  /* 5.4: several user values, any value type, independent slots. */
  { int uidx, i;
    p = lua_newuserdatauv(L, 3, 4);  /* odd payload size: user values are aligned behind it */
    uidx = lua_gettop(L);
    memset(p, 0x5a, 3);
    ok(lua_getiuservalue(L, uidx, 4) == LUA_TNIL && lua_isnil(L, -1),
       "newuserdatauv(3,4): user value 4 starts nil");
    lua_pop(L, 1);
    ok(lua_getiuservalue(L, uidx, 5) == LUA_TNONE && lua_isnil(L, -1),
       "newuserdatauv(3,4): user value 5 is none");
    lua_pop(L, 1);
    lua_pushinteger(L, 42); ok(lua_setiuservalue(L, uidx, 1) == 1, "set uv1 integer");
    lua_pushboolean(L, 1); ok(lua_setiuservalue(L, uidx, 2) == 1, "set uv2 boolean");
    lua_pushnumber(L, 2.5); ok(lua_setiuservalue(L, uidx, 3) == 1, "set uv3 float");
    lua_pushstring(L, "four"); ok(lua_setiuservalue(L, uidx, 4) == 1, "set uv4 string");
    ok(lua_getiuservalue(L, uidx, 1) == LUA_TNUMBER && lua_tointeger(L, -1) == 42,
       "get uv1 integer 42");
    ok(lua_getiuservalue(L, uidx, 2) == LUA_TBOOLEAN && lua_toboolean(L, -1),
       "get uv2 true");
    ok(lua_getiuservalue(L, uidx, 3) == LUA_TNUMBER && lua_tonumber(L, -1) == 2.5,
       "get uv3 2.5");
    ok(lua_getiuservalue(L, uidx, 4) == LUA_TSTRING &&
       strcmp(lua_tostring(L, -1), "four") == 0, "get uv4 'four'");
    lua_pop(L, 4);
    ok(((unsigned char *)p)[0] == 0x5a && ((unsigned char *)p)[2] == 0x5a,
       "payload untouched by user values");
    ok(lua_objlen(L, uidx) == 3, "objlen is the payload size");  /* lua_rawlen: not in lua.h yet */
    /* The user values keep their objects alive across a full GC. */
    lua_newtable(L); lua_pushinteger(L, 7); lua_rawseti(L, -2, 1);
    ok(lua_setiuservalue(L, uidx, 2) == 1, "set uv2 table");
    for (i = 0; i < 3; i++) lua_gc(L, LUA_GCCOLLECT, 0);
    lua_getiuservalue(L, uidx, 2);
    lua_rawgeti(L, -1, 1);
    ok(lua_tointeger(L, -1) == 7, "uv2 table survives collectgarbage (marked)");
    lua_pop(L, 2);
    lua_pop(L, 1);
  }
  lua_close(L);
}

static void test_iuservalue(void)
{
  lua_State *L = newL();
  lua_newuserdatauv(L, 4, 1);  /* userdata at index 1 */
  ok(lua_getiuservalue(L, 1, 1) == LUA_TNIL, "getiuservalue(1) initial nil type");
  lua_pop(L, 1);
  ok(lua_getiuservalue(L, 1, 0) == LUA_TNONE && lua_isnil(L, -1),
     "getiuservalue(0) is none/nil");
  lua_pop(L, 1);
  ok(lua_getiuservalue(L, 1, 2) == LUA_TNONE && lua_isnil(L, -1),
     "getiuservalue(2) is none/nil");
  lua_pop(L, 1);
  /* string roundtrip */
  lua_pushstring(L, "user-value");
  ok(lua_setiuservalue(L, 1, 1) == 1 && lua_gettop(L) == 1,
     "setiuservalue(1) string");
  ok(lua_getiuservalue(L, 1, 1) == LUA_TSTRING &&
     strcmp(lua_tostring(L, -1), "user-value") == 0,
     "getiuservalue(1) string roundtrip");
  lua_pop(L, 1);
  /* table roundtrip */
  lua_newtable(L);
  ok(lua_setiuservalue(L, 1, 1) == 1, "setiuservalue(1) table");
  ok(lua_getiuservalue(L, 1, 1) == LUA_TTABLE && lua_istable(L, -1),
     "getiuservalue(1) table roundtrip");
  lua_pop(L, 1);
  /* userdata roundtrip */
  lua_newuserdatauv(L, 4, 0);
  ok(lua_setiuservalue(L, 1, 1) == 1, "setiuservalue(1) userdata");
  ok(lua_getiuservalue(L, 1, 1) == LUA_TUSERDATA, "getiuservalue(1) userdata");
  lua_pop(L, 1);
  /* nil roundtrip */
  lua_pushnil(L);
  ok(lua_setiuservalue(L, 1, 1) == 1, "setiuservalue(1) nil");
  ok(lua_getiuservalue(L, 1, 1) == LUA_TNIL && lua_isnil(L, -1),
     "getiuservalue(1) nil roundtrip");
  lua_pop(L, 1);
  /* 5.4: non-GC values are user values too. */
  lua_pushinteger(L, 42);
  ok(lua_setiuservalue(L, 1, 1) == 1 && lua_gettop(L) == 1,
     "setiuservalue(1) number");
  ok(lua_getiuservalue(L, 1, 1) == LUA_TNUMBER && lua_tointeger(L, -1) == 42,
     "getiuservalue(1) number roundtrip");
  lua_pop(L, 1);
  /* out-of-range set returns 0 and still pops its value (PUC behaviour). */
  lua_pushinteger(L, 7);
  ok(lua_setiuservalue(L, 1, 2) == 0 && lua_gettop(L) == 1,
     "setiuservalue(2) -> 0, value popped");
  lua_pop(L, 1);
  /* nuvalue 0 + lua_setfenv must not grow the user-value count (PUC). */
  { int uidx = lua_gettop(L)+1;
    lua_newuserdatauv(L, 4, 0);
    lua_newtable(L);
    ok(lua_setfenv(L, uidx) == 1, "setfenv on nuvalue=0 userdata");
    ok(lua_getiuservalue(L, uidx, 1) == LUA_TNONE,
       "nuvalue=0 stays T_NONE after setfenv");
    lua_pop(L, 1);
  }
  /* 5.1 fenv view: a plain table env must never be a mistagged object. */
  { int uidx = lua_gettop(L)+1;
    lua_newuserdata(L, 4);
    lua_newtable(L);
    lua_setfenv(L, uidx);
    lua_getfenv(L, uidx);
    ok(lua_type(L, -1) == LUA_TTABLE || lua_isnil(L, -1),
       "getfenv(userdata) yields table or nil, never a mistagged object");
    lua_pop(L, 2);
  }
  lua_close(L);
}

static int warn_state(lua_State *L)
{
  int st;
  lua_pushliteral(L, "_LJ_WARN_STATE");
  lua_rawget(L, LUA_REGISTRYINDEX);
  st = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : -1;
  lua_pop(L, 1);
  return st;
}

static void test_warning(void)
{
  lua_State *L = newL();
  /* PUC 5.4: luaL_newstate defaults to warnings OFF; warn('@on') enables. */
  ok(warn_state(L) == 0, "warn state defaults off (PUC luaL_newstate)");
  lua_getglobal(L, "warn");
  ok(lua_type(L, -1) == LUA_TFUNCTION, "base warn builtin exists");
  lua_pop(L, 1);
  ok(luaL_dostring(L, "warn()") != LUA_OK, "warn() with no args errors");
  lua_pop(L, 1);
  ok(luaL_dostring(L, "warn(true)") != LUA_OK, "warn(true) errors (no boolean tocont)");
  lua_pop(L, 1);
  ok(luaL_dostring(L, "warn('@on')") == LUA_OK, "warn('@on') ok");
  ok(warn_state(L) == 1, "warn('@on') enables");
  ok(luaL_dostring(L, "warn('@off')") == LUA_OK, "warn('@off') ok");
  ok(warn_state(L) == 0, "warn('@off') disables");
  ok(luaL_dostring(L, "warn('@bogus')") == LUA_OK, "unknown '@...' ignored");
  ok(warn_state(L) == 0, "unknown control leaves state off");
  /* lua_warning does NOT dispatch to a Lua replacement of warn (PUC hook). */
  luaL_dostring(L,
    "warnlog = {}\n"
    "function warn(m, c) warnlog[#warnlog+1] = m end");
  {
    int top = lua_gettop(L);
    lua_warning(L, "hello", 0);
    ok(lua_gettop(L) == top, "lua_warning leaves stack unchanged");
  }
  lua_getglobal(L, "warnlog");
  ok(luaL_len(L, -1) == 0, "lua_warning ignores a Lua warn replacement");
  lua_pop(L, 1);
  /* The emitter keeps its continuation state; direct calls work. */
  lua_warning(L, "@on", 0);
  ok(warn_state(L) == 1, "lua_warning('@on') enables");
  lua_warning(L, "part1", 1);
  ok(warn_state(L) == 2, "tocont=1 marks continuation");
  lua_warning(L, "part2", 0);
  ok(warn_state(L) == 1, "tocont=0 finishes the message");
  lua_close(L);
}

static void warn_hook(void *ud, const char *msg, int tocont)
{
  int *n = (int *)ud;
  n[0]++;
  n[1] = tocont;
  n[2] = msg[0];
}

static void test_warnf(void)
{
  lua_State *L = newL();
  int state[3] = {0, -1, 0};
  lua_setwarnf(L, warn_hook, state);
  lua_warning(L, "hook", 0);
  ok(state[0] == 1 && state[1] == 0 && state[2] == 'h',
     "lua_setwarnf hook receives (msg, tocont)");
  lua_warning(L, "@off", 0);  /* a custom hook sees control messages too */
  ok(state[0] == 2 && state[2] == '@', "custom hook sees control messages");
  lua_setwarnf(L, NULL, NULL);
  ok(warn_state(L) == 0, "lua_setwarnf(NULL) restores the default emitter");
  lua_close(L);
}

static void test_resume54(void)
{
  lua_State *L = newL();
  lua_State *co;
  int nres = -1;
  luaL_dostring(L, "co = coroutine.create(function() return 1, 2 end)");
  lua_getglobal(L, "co");
  co = lua_tothread(L, -1);
  ok(co != NULL, "resume54: coroutine object");
  ok(lua_resume(co, L, 0, &nres) == LUA_OK, "lua_resume(co, from, 0, &nres) OK");
  ok(nres == 2, "lua_resume sets *nres to the result count");
  lua_pop(L, 1);
  lua_close(L);
}

static int cont_calls;
static int cont_k(lua_State *L, int status, lua_KContext ctx)
{
  (void)L; (void)status; (void)ctx;
  cont_calls++;
  return 0;
}
static int add_c(lua_State *L)
{
  lua_Integer a = lua_tointeger(L, 1), b = lua_tointeger(L, 2);
  lua_pushinteger(L, a + b);
  return 1;
}
static int error_c(lua_State *L)
{
  lua_pushliteral(L, "boom");
  return lua_error(L);
}
static int callk_error(lua_State *L)
{
  lua_pushcfunction(L, error_c);
  lua_pushliteral(L, "boom");
  lua_callk(L, 1, 0, 0, cont_k);
  return 0;
}
static int handler_c(lua_State *L)
{
  lua_pushliteral(L, "handled");
  return 1;
}
static int yield0_c(lua_State *L)
{
  lua_pushinteger(L, 7);
  return lua_yieldk(L, 1, 0, NULL);
}
static int yieldk_c(lua_State *L)
{
  lua_pushinteger(L, 8);
  return lua_yieldk(L, 1, 0, cont_k);
}
static int pcallk_yield_c(lua_State *L)
{
  int st;
  lua_getglobal(L, "yielder");
  st = lua_pcallk(L, 0, 1, 0, 0, cont_k);
  if (st != LUA_OK) {
    lua_pushinteger(L, st);
    lua_insert(L, -2);  /* status, error object */
    return 2;
  }
  return 1;
}
static void check_err(lua_State *L, const char *needle, const char *name)
{
  const char *m = lua_tostring(L, -1);
  ok(m != NULL && strstr(m, needle) != NULL, name);
}

static void test_continuations(void)
{
  lua_State *L = newL();
  int st;
  cont_calls = 0;

  /* callk success: k is never invoked. */
  lua_pushcfunction(L, add_c);
  lua_pushinteger(L, 2); lua_pushinteger(L, 3);
  lua_callk(L, 2, 1, 0, cont_k);
  ok(lua_tointeger(L, -1) == 5, "lua_callk success returns the result");
  ok(cont_calls == 0, "lua_callk does not invoke k");
  lua_pop(L, 1);

  /* callk error: propagates like lua_call, caught by a Lua pcall. */
  lua_pushcfunction(L, callk_error);
  lua_setglobal(L, "callk_error");
  luaL_dostring(L, "ok1, msg1 = pcall(function() return callk_error() end)");
  lua_getglobal(L, "ok1");
  ok(!lua_toboolean(L, -1), "lua_callk error propagates");
  lua_pop(L, 1);
  lua_getglobal(L, "msg1");
  check_err(L, "boom", "lua_callk error object");
  lua_pop(L, 1);

  /* pcallk success. */
  lua_pushcfunction(L, add_c);
  lua_pushinteger(L, 4); lua_pushinteger(L, 5);
  st = lua_pcallk(L, 2, 1, 0, 0, cont_k);
  ok(st == LUA_OK && lua_tointeger(L, -1) == 9,
     "lua_pcallk success returns the result");
  ok(cont_calls == 0, "lua_pcallk does not invoke k");
  lua_pop(L, 1);

  /* pcallk error without a handler. */
  lua_pushcfunction(L, error_c);
  lua_pushliteral(L, "boom");
  st = lua_pcallk(L, 1, 0, 0, 0, cont_k);
  ok(st == LUA_ERRRUN, "lua_pcallk error status");
  check_err(L, "boom", "lua_pcallk error object");
  lua_pop(L, 1);

  /* pcallk error with an error handler (index 1). */
  lua_settop(L, 0);
  lua_pushcfunction(L, handler_c);
  lua_pushcfunction(L, error_c);
  lua_pushliteral(L, "boom");
  st = lua_pcallk(L, 1, 0, 1, 0, cont_k);
  ok(st == LUA_ERRRUN && lua_isstring(L, -1) &&
     strcmp(lua_tostring(L, -1), "handled") == 0,
     "lua_pcallk uses the error handler");
  lua_pop(L, 2);  /* handler and result */
  ok(cont_calls == 0, "lua_pcallk never invokes k (all cases)");

  /* lua_yieldk with k == NULL: a tail yield from a C function. */
  lua_pushcfunction(L, yield0_c);
  lua_setglobal(L, "yield0_c");
  luaL_dostring(L, "co1 = coroutine.create(function() return yield0_c() end)");
  lua_getglobal(L, "co1");
  {
    lua_State *co = lua_tothread(L, -1);
    int nres = -1;
    st = lua_resume(co, L, 0, &nres);
    ok(st == LUA_YIELD && nres == 1 && lua_tointeger(co, -1) == 7,
       "lua_yieldk(NULL) yields from a C tail call");
  }
  lua_pop(L, 1);

  /* lua_yieldk with a continuation: refused, not silently skipped. */
  lua_pushcfunction(L, yieldk_c);
  lua_setglobal(L, "yieldk_c");
  luaL_dostring(L, "co2 = coroutine.create(function() return yieldk_c() end)");
  lua_getglobal(L, "co2");
  {
    lua_State *co = lua_tothread(L, -1);
    int nres = -1;
    st = lua_resume(co, L, 0, &nres);
    ok(st == LUA_ERRRUN, "lua_yieldk(k != NULL) is refused");
    check_err(co, "attempt to yield across a C-call boundary",
             "lua_yieldk(k != NULL) error wording");
  }
  lua_pop(L, 1);

  /* A yield over lua_pcallk is a clean, documented error. */
  lua_pushcfunction(L, pcallk_yield_c);
  lua_setglobal(L, "pcallk_yield_c");
  luaL_dostring(L,
    "yielder = function() return coroutine.yield(9) end\n"
    "co3 = coroutine.create(function() return pcallk_yield_c() end)");
  lua_getglobal(L, "co3");
  {
    lua_State *co = lua_tothread(L, -1);
    int nres = -1;
    st = lua_resume(co, L, 0, &nres);
    ok(st == LUA_OK && nres == 2 && lua_tointeger(co, -2) == LUA_ERRRUN,
       "yield over lua_pcallk returns LUA_ERRRUN");
    lua_pushvalue(co, -1);
    lua_xmove(co, L, 1);
    check_err(L, "attempt to yield across a C-call boundary",
              "yield over lua_pcallk error wording");
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  ok(cont_calls == 0, "no continuation callback ran in any case");
  lua_close(L);
}

static int close_calls;
static int arith_c(lua_State *L)
{
  int op = (int)lua_tointeger(L, 1);
  lua_pushvalue(L, 2);
  lua_pushvalue(L, 3);
  lua_arith(L, op);
  return 1;
}

static void test_arith(void)
{
  lua_State *L = newL();
  int top;
  lua_Integer big = (lua_Integer)0x7fffffffffffffffLL;
  lua_Integer min = (lua_Integer)0x8000000000000000LL;

  top = lua_gettop(L);
  lua_pushinteger(L, 2); lua_pushinteger(L, 3);
  lua_arith(L, LUA_OPADD);
  ok(lua_gettop(L) == top+1 && lua_isinteger(L, -1) &&
     lua_tointeger(L, -1) == 5, "lua_arith ADD int + stack effect");
  lua_pop(L, 1);

  lua_pushinteger(L, 2); lua_pushnumber(L, 3.5);
  lua_arith(L, LUA_OPADD);
  ok(lua_isnumber(L, -1) && !lua_isinteger(L, -1) && lua_tonumber(L, -1) == 5.5,
     "lua_arith ADD mixed -> float");
  lua_pop(L, 1);

  lua_pushinteger(L, 2147483647); lua_pushinteger(L, 1);
  lua_arith(L, LUA_OPADD);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 2147483648LL,
     "lua_arith ADD int boundary -> integer");
  lua_pop(L, 1);

  lua_pushinteger(L, -2147483648); lua_pushinteger(L, 1);
  lua_arith(L, LUA_OPSUB);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == -2147483649LL,
     "lua_arith SUB int boundary -> integer");
  lua_pop(L, 1);

  lua_pushinteger(L, 2147483647); lua_pushinteger(L, 2147483647);
  lua_arith(L, LUA_OPMUL);
  ok(lua_isinteger(L, -1) &&
     lua_tointeger(L, -1) == 4611686014132420609LL,
     "lua_arith MUL >2^53 exact");
  lua_pop(L, 1);

  lua_pushinteger(L, big); lua_pushinteger(L, 1);
  lua_arith(L, LUA_OPADD);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == (lua_Integer)0x8000000000000000LL,
     "lua_arith integer overflow wraps");
  lua_pop(L, 1);

  lua_pushinteger(L, 7); lua_pushinteger(L, 2);
  lua_arith(L, LUA_OPDIV);
  ok(!lua_isinteger(L, -1) && lua_tonumber(L, -1) == 3.5,
     "lua_arith / always float");
  lua_pop(L, 1);
  lua_pushinteger(L, 1); lua_pushinteger(L, 0);
  lua_arith(L, LUA_OPDIV);
  ok(!lua_isinteger(L, -1) && lua_tonumber(L, -1) == (lua_Number)INFINITY,
     "lua_arith 1/0 is float inf");
  lua_pop(L, 1);

  lua_pushinteger(L, -7); lua_pushinteger(L, 3);
  lua_arith(L, LUA_OPIDIV);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == -3,
     "lua_arith // floor division");
  lua_pop(L, 1);
  lua_pushinteger(L, min); lua_pushinteger(L, -1);
  lua_arith(L, LUA_OPIDIV);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == (lua_Integer)0x8000000000000000LL,
     "lua_arith mininteger // -1");
  lua_pop(L, 1);

  lua_pushinteger(L, -7); lua_pushinteger(L, 3);
  lua_arith(L, LUA_OPMOD);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 2,
     "lua_arith % takes divisor sign");
  lua_pop(L, 1);
  lua_pushinteger(L, min); lua_pushinteger(L, -1);
  lua_arith(L, LUA_OPMOD);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 0,
     "lua_arith mininteger % -1");
  lua_pop(L, 1);

  lua_pushinteger(L, 2); lua_pushinteger(L, 3);
  lua_arith(L, LUA_OPPOW);
  ok(!lua_isinteger(L, -1) && lua_tonumber(L, -1) == 8.0,
     "lua_arith ^ is float");
  lua_pop(L, 1);

  lua_pushinteger(L, 12); lua_pushinteger(L, 10);
  lua_arith(L, LUA_OPBAND);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 8, "lua_arith &");
  lua_pop(L, 1);
  lua_pushinteger(L, 12); lua_pushinteger(L, 10);
  lua_arith(L, LUA_OPBOR);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 14, "lua_arith |");
  lua_pop(L, 1);
  lua_pushinteger(L, 12); lua_pushinteger(L, 10);
  lua_arith(L, LUA_OPBXOR);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 6, "lua_arith ~ binary");
  lua_pop(L, 1);
  lua_pushinteger(L, 1); lua_pushinteger(L, 40);
  lua_arith(L, LUA_OPSHL);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 1099511627776LL,
     "lua_arith << 40 exact");
  lua_pop(L, 1);
  lua_pushinteger(L, -1); lua_pushinteger(L, 1);
  lua_arith(L, LUA_OPSHR);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == big,
     "lua_arith >> is logical");
  lua_pop(L, 1);

  top = lua_gettop(L);
  lua_pushinteger(L, -2147483648);
  lua_arith(L, LUA_OPUNM);
  ok(lua_gettop(L) == top+1 && lua_isinteger(L, -1) &&
     lua_tointeger(L, -1) == 2147483648LL, "lua_arith unary - boundary");
  lua_pop(L, 1);
  lua_pushinteger(L, 2147483648LL);  /* boxed literal value */
  lua_arith(L, LUA_OPBNOT);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == -2147483649LL,
     "lua_arith unary ~ beyond int32");
  lua_pop(L, 1);

  lua_pushnumber(L, 3.0); lua_pushinteger(L, 1);
  lua_arith(L, LUA_OPBAND);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 1,
     "lua_arith exact float bit operand");
  lua_pop(L, 1);

  luaL_dostring(L, "mt = setmetatable({}, {__add=function(a,b) return 42 end})");
  lua_getglobal(L, "mt");
  lua_pushinteger(L, 5);
  lua_arith(L, LUA_OPADD);
  ok(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 42,
     "lua_arith invokes __add");
  lua_pop(L, 1);

  lua_pushcfunction(L, arith_c);
  lua_setglobal(L, "arith_c");
  luaL_dostring(L,
    "ok1, msg1 = pcall(arith_c, 6, 1, 0)\n"
    "ok2, msg2 = pcall(arith_c, 3, 3, 0)\n"
    "ok3, msg3 = pcall(arith_c, 7, 3.5, 1)");
  /* Wording verified against PUC 5.4.9 (lvm.c: "attempt to divide by zero");
  ** the integer '%' keeps PUC's "attempt to perform 'n%%0'". */
  lua_getglobal(L, "ok1"); ok(!lua_toboolean(L, -1), "lua_arith 1//0 errors"); lua_pop(L,1);
  lua_getglobal(L, "msg1"); ok(lua_isstring(L,-1) && strstr(lua_tostring(L,-1), "divide by zero"), "lua_arith // error wording"); lua_pop(L,1);
  lua_getglobal(L, "ok2"); ok(!lua_toboolean(L, -1), "lua_arith 3%0 errors"); lua_pop(L,1);
  lua_getglobal(L, "ok3"); ok(!lua_toboolean(L, -1), "lua_arith inexact float bit errors"); lua_pop(L,1);
  lua_close(L);
}

static void test_buffer_api(void)
{
  lua_State *L = newL();
  int top = lua_gettop(L);
  luaL_Buffer b;
  char *p;
  luaL_buffinit(L, &b);
  ok(lua_gettop(L) == top+1, "luaL_buffinit keeps one placeholder slot");
  ok(luaL_bufflen(&b) == 0 && luaL_buffaddr(&b) == b.init.b,
     "luaL_bufflen/addr at init");
  luaL_addstring(&b, "abc");
  ok(luaL_bufflen(&b) == 3 && memcmp(luaL_buffaddr(&b), "abc", 3) == 0,
     "luaL_addstring updates len/addr");
  p = luaL_prepbuffsize(&b, 20000);
  ok(p != NULL, "luaL_prepbuffsize large");
  memset(p, 'x', 20000);
  luaL_addsize(&b, 20000);
  ok(luaL_bufflen(&b) == 20003 && luaL_buffaddr(&b) != b.init.b,
     "large buffer moved out of the inline box");
  luaL_pushresult(&b);
  ok(lua_gettop(L) == top+1 && lua_rawlen(L, -1) == 20003 &&
     lua_tolstring(L, -1, NULL)[0] == 'a' &&
     lua_tolstring(L, -1, NULL)[3] == 'x',
     "luaL_pushresult returns the gathered string");
  lua_pop(L, 1);

  luaL_buffinit(L, &b);
  p = luaL_buffinitsize(L, &b, 100);
  ok(p != NULL && luaL_bufflen(&b) == 0, "luaL_buffinitsize returns space");
  memset(p, 'y', 100);
  luaL_pushresultsize(&b, 100);
  ok(lua_rawlen(L, -1) == 100 && lua_tolstring(L, -1, NULL)[0] == 'y',
     "luaL_pushresultsize commits size");
  lua_pop(L, 1);

  luaL_buffinit(L, &b);
  luaL_addstring(&b, "ab");
  lua_pushliteral(L, "cd");
  luaL_addvalue(&b);
  luaL_pushresult(&b);
  ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "abcd") == 0,
     "luaL_addvalue appends the top string");
  lua_pop(L, 1);
  lua_close(L);
}

static int mark_return_c(lua_State *L)
{
  lua_getglobal(L, "close_obj");
  lua_toclose(L, -1);
  return 1;
}
static int close_now_c(lua_State *L)
{
  lua_getglobal(L, "close_obj");
  lua_toclose(L, -1);
  lua_closeslot(L, -1);
  return 0;
}
static int close_settop_c(lua_State *L)
{
  lua_getglobal(L, "close_obj");
  lua_toclose(L, -1);
  lua_settop(L, 0);
  return 0;
}
/* __close that recurses deep: the recursive Lua calls grow the Lua stack, so
** the stack really moves while lua_closeslot/lua_settop hold a TValue *. */
static void push_deep_close(lua_State *L, const char *global)
{
  luaL_dostring(L,
    "local function mk(name)\n"
    "  _G[name] = setmetatable({}, {__close=function()\n"
    "    _G[name..'_n'] = (_G[name..'_n'] or 0) + 1\n"
    "    local function deep(n) if n == 0 then return 0 end return 1 + deep(n-1) end\n"
    "    deep(400)\n"
    "  end})\n"
    "end\n"
    "mk('deep_close_obj'); mk('deep_settop_obj')");
  lua_getglobal(L, global);
  lua_toclose(L, -1);
}

static int closeslot_deep_c(lua_State *L)
{
  push_deep_close(L, "deep_close_obj");
  lua_closeslot(L, -1);          /* the close grows the stack */
  lua_pushinteger(L, 42);        /* would write through a stale L->top */
  lua_pushinteger(L, lua_gettop(L));
  return 2;
}

/* Grow a luaL_Buffer far past LUAL_BUFFERSIZE with the C stack nearly full:
** luaL_pushresult then closes the buffer's box through lua_closeslot while the
** stack is exhausted, which used to leave L->top pointing into a freed block. */
static int grow_buffer_c(lua_State *L)
{
  luaL_Buffer b;
  char *p;
  TValue *stack_before;
  size_t i, total = 3*LUAL_BUFFERSIZE + 123;
  char last = (char)('a' + (int)((total-1) % 26));
  int nfill = 0, moved;
  lua_settop(L, 0);
  /* Leave exactly 22 free slots before buffinit: placeholder 21, box swap
  ** 21, pushlstring 20, error anchor 19; the closer's checkstack(20) must
  ** grow the stack. Fill BEFORE buffinit so the fillers stay below the box. */
  while (tvref(L->maxstack) - L->top > 22) {
    lua_pushinteger(L, nfill);
    nfill++;
  }
  luaL_buffinit(L, &b);
  p = luaL_prepbuffsize(&b, total);
  for (i = 0; i < total; i++) p[i] = (char)('a' + (int)(i % 26));
  luaL_addsize(&b, total);
  stack_before = tvref(L->stack);
  luaL_pushresultsize(&b, 0);  /* closes the box on an exhausted stack */
  moved = tvref(L->stack) != stack_before;
  ok(moved, "box close moved the Lua stack");
  ok(lua_gettop(L) == nfill+1,
     "pushresult leaves exactly the string above the fillers");
  ok(lua_rawlen(L, -1) == total &&
     lua_tolstring(L, -1, NULL)[0] == 'a' &&
     lua_tolstring(L, -1, NULL)[total-1] == last,
     "pushresult returns the gathered buffer string");
  lua_pushinteger(L, (lua_Integer)lua_rawlen(L, -1));
  return 2;
}

static int settop_err_c(lua_State *L)
{
  lua_getglobal(L, "settop_err_obj");
  lua_toclose(L, -1);
  lua_settop(L, 0);  /* closes the slot, whose __close grows the stack and errors */
  return 0;
}

static int yield_err_c(lua_State *L)
{
  lua_getglobal(L, "yield_err_obj");
  lua_toclose(L, -1);
  lua_pushinteger(L, 7);
  return lua_yield(L, 1);
}

static int yield_yield_c(lua_State *L)
{
  lua_getglobal(L, "yield_yield_obj");
  lua_toclose(L, -1);
  lua_pushinteger(L, 7);
  return lua_yield(L, 1);
}

static int addvalue_boxed_c(lua_State *L)
{
  luaL_Buffer b;
  char *p;
  lua_settop(L, 0);
  luaL_buffinit(L, &b);
  p = luaL_prepbuffsize(&b, LUAL_BUFFERSIZE + 10);  /* force a boxed buffer */
  memset(p, 'z', LUAL_BUFFERSIZE + 10);
  luaL_addsize(&b, LUAL_BUFFERSIZE + 10);
  lua_pushliteral(L, "tail");
  luaL_addvalue(&b);  /* box lives below the string: -2 path */
  luaL_pushresult(&b);
  lua_pushinteger(L, (lua_Integer)lua_rawlen(L, -1));
  return 2;
}

static int yield_tbc_c(lua_State *L)
{
  lua_getglobal(L, "yield_obj");
  lua_toclose(L, -1);
  lua_pushinteger(L, 7);
  return lua_yield(L, 1);
}

static int mark_error_c(lua_State *L)
{
  lua_getglobal(L, "close_err_obj");
  lua_toclose(L, -1);
  return 0;
}
static int argexpected_c(lua_State *L)
{
  luaL_argexpected(L, lua_isinteger(L, 1), 1, "integer");
  return 0;
}

static void test_toclose(void)
{
  lua_State *L = newL_sys();
  lua_pushcfunction(L, mark_return_c); lua_setglobal(L, "mark_return_c");
  lua_pushcfunction(L, close_now_c); lua_setglobal(L, "close_now_c");
  lua_pushcfunction(L, close_settop_c); lua_setglobal(L, "close_settop_c");
  lua_pushcfunction(L, mark_error_c); lua_setglobal(L, "mark_error_c");
  lua_pushcfunction(L, grow_buffer_c); lua_setglobal(L, "grow_buffer_c");
  lua_pushcfunction(L, addvalue_boxed_c); lua_setglobal(L, "addvalue_boxed_c");
  lua_pushcfunction(L, settop_err_c); lua_setglobal(L, "settop_err_c");
  lua_pushcfunction(L, closeslot_deep_c); lua_setglobal(L, "closeslot_deep_c");
  lua_pushcfunction(L, yield_tbc_c); lua_setglobal(L, "yield_tbc_c");
  lua_pushcfunction(L, yield_err_c); lua_setglobal(L, "yield_err_c");
  lua_pushcfunction(L, yield_yield_c); lua_setglobal(L, "yield_yield_c");
  lua_pushcfunction(L, argexpected_c); lua_setglobal(L, "argexpected_c");
  close_calls = 0;
  luaL_dostring(L,
    "close_calls = 0\n"
    "close_obj = setmetatable({}, {__close=function() close_calls=close_calls+1 end})\n"
    "local r = mark_return_c()\n"
    "assert(r == close_obj)");
  lua_getglobal(L, "close_calls");
  ok(lua_tointeger(L, -1) == 1, "lua_toclose closes on C return");
  lua_pop(L, 1);

  close_calls = 0;
  luaL_dostring(L, "close_calls=0; close_obj = setmetatable({}, {__close=function() close_calls=close_calls+1 end}); close_now_c()");
  lua_getglobal(L, "close_calls");
  ok(lua_tointeger(L, -1) == 1, "lua_closeslot closes immediately");
  lua_pop(L, 1);

  close_calls = 0;
  luaL_dostring(L, "close_calls=0; close_obj = setmetatable({}, {__close=function() close_calls=close_calls+1 end}); close_settop_c()");
  lua_getglobal(L, "close_calls");
  ok(lua_tointeger(L, -1) == 1, "lua_settop closes a removed tbc slot");
  lua_pop(L, 1);

  luaL_dostring(L,
    "close_err_obj = setmetatable({}, {__close=function() error('boom') end})\n"
    "okerr, errmsg = pcall(mark_error_c)");
  lua_getglobal(L, "okerr");
  ok(!lua_toboolean(L, -1), "lua_toclose propagates a __close error");
  lua_pop(L, 1);
  lua_getglobal(L, "errmsg");
  ok(lua_isstring(L, -1) && strstr(lua_tostring(L, -1), "boom"), "lua_toclose __close error object");
  lua_pop(L, 1);

  /* Same through lua_settop: the error object must survive the stack move. */
  luaL_dostring(L,
    "local function deep(n) if n == 0 then return 0 end return 1 + deep(n-1) end\n"
    "settop_err_obj = setmetatable({}, {__close=function() deep(400); error('boom') end})\n"
    "okset, msgset = pcall(settop_err_c)");
  luaL_dostring(L,
    "cs1, cs2 = closeslot_deep_c()\n"
    "closed_deep = deep_close_obj_n or 0");
  lua_getglobal(L, "cs1");
  ok(lua_tointeger(L, -1) == 42, "lua_closeslot survives a stack-growing __close");
  lua_pop(L, 1);
  lua_getglobal(L, "closed_deep");
  ok(lua_tointeger(L, -1) == 1, "lua_closeslot runs the deep __close once");
  lua_pop(L, 1);
  lua_getglobal(L, "okset");
  ok(!lua_toboolean(L, -1), "lua_settop propagates a __close error");
  lua_pop(L, 1);
  lua_getglobal(L, "msgset");
  ok(lua_isstring(L, -1) && strstr(lua_tostring(L, -1), "boom"),
     "lua_settop keeps the __close error string");
  lua_pop(L, 1);

  /* LUAL_BUFFERSIZE is a C macro; expose it to the Lua chunk. */
  lua_pushinteger(L, LUAL_BUFFERSIZE);
  lua_setglobal(L, "LUAL_BUFFERSIZE");
  {
    int st = luaL_dostring(L,
      "local s, n = grow_buffer_c()\n"
      "assert(#s == 3*LUAL_BUFFERSIZE + 123 and n == #s, n)\n"
      "local t, m = addvalue_boxed_c()\n"
      "assert(m == LUAL_BUFFERSIZE + 14 and t:sub(-4) == 'tail', m)");
    ok(st == LUA_OK, st == LUA_OK ? "buffer growth and boxed addvalue checks ran"
                                  : lua_tostring(L, -1));
    if (st != LUA_OK) lua_pop(L, 1);
  }

  luaL_dostring(L, "ok, msg = pcall(argexpected_c, {})");
  lua_getglobal(L, "ok");
  ok(!lua_toboolean(L, -1), "luaL_argexpected rejects wrong type");
  lua_pop(L, 1);
  ok(luaL_dostring(L, "argexpected_c(42)") == LUA_OK,
     "luaL_argexpected accepts expected type");
  ok(INT_MAX == 2147483647, "<limits.h> reachable through lua.h");

  /* __close errors / yields at yield time: the coroutine gets that error on
  ** the resume, instead of yielding the value and raising later (FORK row). */
  luaL_dostring(L,
    "yield_err_obj = setmetatable({}, {__close=function() error('boom') end})\n"
    "yield_yield_obj = setmetatable({}, {__close=function() coroutine.yield('inside') end})\n"
    "co_err = coroutine.create(function() local v = yield_err_c(); return v end)\n"
    "ok_e, msg_e = coroutine.resume(co_err)\n"
    "co_y = coroutine.create(function() local v = yield_yield_c(); return v end)\n"
    "ok_y, msg_y = coroutine.resume(co_y)");
  lua_getglobal(L, "ok_e"); ok(!lua_toboolean(L, -1), "yield + __close error resumes with an error"); lua_pop(L,1);
  lua_getglobal(L, "msg_e"); ok(lua_isstring(L,-1) && strstr(lua_tostring(L,-1), "boom"), "yield + __close error keeps 'boom'"); lua_pop(L,1);
  lua_getglobal(L, "ok_y"); ok(!lua_toboolean(L, -1), "yield + __close yield resumes with an error"); lua_pop(L,1);
  lua_getglobal(L, "msg_y"); ok(lua_isstring(L,-1) && strstr(lua_tostring(L,-1), "across a C-call boundary"), "yield + __close yield wording"); lua_pop(L,1);

  /* Last: a yield needs the whole process to survive a panic on old code. */

  /* A yield from a C function with a pending lua_toclose slot: the slot is
  ** closed at yield time, the value is delivered, and the resume finishes
  ** without closing anything twice. */
  luaL_dostring(L,
    "closed_yield = 0\n"
    "yield_obj = setmetatable({}, {__close=function() closed_yield = closed_yield + 1 end})\n"
    "co = coroutine.create(function() local v = yield_tbc_c(); return v end)\n"
    "ok1, v1 = coroutine.resume(co)\n"
    "closed_at_yield = closed_yield\n"
    "ok2, v2 = coroutine.resume(co, 99)\n"
    "closed_final = closed_yield");
  lua_getglobal(L, "ok1"); ok(lua_toboolean(L, -1), "yield with tbc slot resumes"); lua_pop(L, 1);
  lua_getglobal(L, "v1"); ok(lua_tointeger(L, -1) == 7, "yield with tbc slot delivers the value"); lua_pop(L, 1);
  lua_getglobal(L, "closed_at_yield");
  ok(lua_tointeger(L, -1) == 1, "lua_yield closes the pending slot at yield time");
  lua_pop(L, 1);
  lua_getglobal(L, "ok2"); ok(lua_toboolean(L, -1), "resume after yield finishes"); lua_pop(L, 1);
  lua_getglobal(L, "v2");
  ok(lua_tointeger(L, -1) == 99, "resume after yield delivers the resume value");
  lua_pop(L, 1);
  lua_getglobal(L, "closed_final");
  ok(lua_tointeger(L, -1) == 1, "the pending slot is closed exactly once");
  lua_pop(L, 1);

  lua_close(L);
}

/* Wraps the allocator of a state: allocation fails once an armed byte
** budget is used up. Wrapping keeps the built-in allocator, so this works on
** targets where the system heap is outside the GC address range. */
static lua_Alloc lim_orig;
static void *lim_origud;
static long long lim_used, lim_max;
static int lim_on;
static void *limalloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
  long long old = ptr ? (long long)osize : 0;
  void *q;
  (void)ud;
  if (nsize == 0) { lim_used -= old; return lim_orig(lim_origud, ptr, osize, 0); }
  if (lim_on && (long long)nsize > old && lim_used - old + (long long)nsize > lim_max)
    return NULL;
  q = lim_orig(lim_origud, ptr, osize, nsize);
  if (q) lim_used += (long long)nsize - old;
  return q;
}

static int lim_arm_c(lua_State *L)
{
  lim_max = lim_used + (long long)lua_tointeger(L, 1);
  lim_on = 1;
  return 0;
}

static int lim_disarm_c(lua_State *L)
{
  (void)L;
  lim_on = 0;
  return 0;
}

/* An out-of-memory error raised inside pcall/xpcall is caught by that call
** and leaves the pcall nesting counter unchanged, with the loop compiled or
** interpreted. The allocation that fails is the tostring() of a number: the
** only allocation of the loop, with and without a guard after it in the
** protected call. The third case fails after the protected call returned. */
static const char *oom_pcall_src =
  "local function depth()\n"
  "  local n = 0\n"
  "  local function rec() n = n + 1; pcall(rec) end\n"
  "  pcall(rec)\n"
  "  return n\n"
  "end\n"
  "local d0 = depth()\n"
  "local out = {}\n"
  "local function case(spin)\n"
  "  spin(300)\n"
  "  collectgarbage()\n"
  "  arm(32768)\n"
  "  local ok, bad = pcall(spin, 10000000)\n"
  "  disarm()\n"
  "  collectgarbage()\n"
  "  out[#out + 1] = tostring(ok) .. ' ' .. tostring(bad) .. ' ' .. (depth() - d0)\n"
  "end\n"
  "case(function(n)\n"
  "  local bad, s = 0, 0.5\n"
  "  for i = 1, n do\n"
  "    local ok, v = pcall(tostring, i + 0.5)\n"
  "    if not ok then bad = bad + 1; break end\n"
  "    s = s + #v\n"
  "  end\n"
  "  return bad\n"
  "end)\n"
  "local xs = {}\n"
  "for i = 1, 64 do xs[i] = i end\n"
  "local function g(x) local s = tostring(x + 0.5); return #s + xs[(x & 63) + 1] end\n"
  "case(function(n)\n"
  "  local bad, s = 0, 0.5\n"
  "  for i = 1, n do\n"
  "    local ok, v = pcall(g, i)\n"
  "    if not ok then bad = bad + 1; break end\n"
  "    s = s + v\n"
  "  end\n"
  "  return bad\n"
  "end)\n"
  "case(function(n)\n"
  "  local bad, s = 0, 0.5\n"
  "  for i = 1, n do\n"
  "    local ok, v = xpcall(tostring, print, i + 0.5)\n"
  "    if not ok then bad = bad + 1; break end\n"
  "    s = s + #v\n"
  "  end\n"
  "  return bad\n"
  "end)\n"
  "local function id(x) return x end\n"
  "case(function(n)\n"
  "  local s = 0.5\n"
  "  for i = 1, n do\n"
  "    local ok, v = pcall(id, i)\n"
  "    s = s + #tostring(v + 0.5)\n"
  "  end\n"
  "  return 'no error'\n"
  "end)\n"
  "out[#out + 1] = tostring(pcall(pcall, pcall, tostring, 'x'))\n"
  "return table.concat(out, '; ')\n";

static void test_oom_pcall(void)
{
  static const char *want =
    "true 1 0; true 1 0; true 1 0; false not enough memory 0; true";
  int jiton;
  for (jiton = 1; jiton >= 0; jiton--) {
    lua_State *L;
    const char *res;
    L = newL();
    lim_used = 0; lim_on = 0;
    lim_orig = lua_getallocf(L, &lim_origud);
    lua_setallocf(L, limalloc, NULL);
    lua_pushcfunction(L, lim_arm_c); lua_setglobal(L, "arm");
    lua_pushcfunction(L, lim_disarm_c); lua_setglobal(L, "disarm");
    if (!jiton) luaL_dostring(L, "if jit then jit.off() end");
    if (luaL_dostring(L, oom_pcall_src)) {
      lim_on = 0;
      printf("oom_pcall (%s): %s\n", jiton ? "jit on" : "jit off",
	     lua_tostring(L, -1));
      ok(0, jiton ? "oom in pcall, jit on: script" : "oom in pcall, jit off: script");
    } else {
      res = lua_tostring(L, -1);
      if (res == NULL || strcmp(res, want) != 0)
	printf("oom_pcall (%s): got '%s'\n", jiton ? "jit on" : "jit off",
	       res ? res : "(nil)");
      ok(res != NULL && strcmp(res, want) == 0,
	 jiton ? "oom in pcall is caught, counter exact (jit on)"
	       : "oom in pcall is caught, counter exact (jit off)");
    }
    lua_close(L);
  }
}

/* closethread helpers: close the thread in argument 1 from the running one,
** and measure the usable pcall nesting depth of a (new or reset) thread. */
static int l_closefrom(lua_State *L)
{
  lua_closethread(lua_tothread(L, 1), L);
  return 0;
}

static lua_Integer thread_depth(lua_State *L, lua_State *co)
{
  int nres = 0;
  lua_Integer d;
  lua_getglobal(co, "depthprobe");
  if (lua_resume(co, L, 0, &nres) != LUA_OK || nres != 1) return -1;
  d = lua_tointeger(co, -1);
  lua_settop(co, 0);
  return d;
}

static void test_closethread(void)
{
  lua_State *L = newL();
  lua_State *co;
  luaL_dostring(L,
    "closed = 0\n"
    "co = coroutine.create(function()\n"
    "  local x <close> = setmetatable({}, {__close=function() closed=closed+1 end})\n"
    "  coroutine.yield(1)\n"
    "end)\n"
    "assert(coroutine.resume(co))");
  lua_getglobal(L, "co");
  co = lua_tothread(L, -1);
  ok(co != NULL && lua_status(co) == LUA_YIELD, "closethread: suspended thread");
  ok(lua_closethread(co, L) == LUA_OK, "lua_closethread returns LUA_OK");
  ok(lua_status(co) == LUA_OK && lua_gettop(co) == 0,
     "lua_closethread resets status and stack");
  lua_getglobal(L, "closed");
  ok(lua_tointeger(L, -1) == 1, "lua_closethread closes pending tbc slots");
  lua_pop(L, 1);
  ok(lua_resetthread(co) == LUA_OK, "lua_resetthread delegates to closethread");
  lua_pop(L, 1);

  /* A thread that died with an error: lua_closethread closes its slots and
  ** returns the ORIGINAL status, with the error object on top (PUC
  ** luaE_resetthread). */
  luaL_dostring(L,
    "dead_closed = 0\n"
    "co_dead = coroutine.create(function()\n"
    "  local x <close> = setmetatable({}, {__close=function() dead_closed = dead_closed + 1 end})\n"
    "  error('boom')\n"
    "end)\n"
    "dead_ok, dead_msg = coroutine.resume(co_dead)");
  lua_getglobal(L, "co_dead");
  co = lua_tothread(L, -1);
  ok(lua_status(co) == LUA_ERRRUN, "closethread: thread died with LUA_ERRRUN");
  ok(lua_closethread(co, L) == LUA_ERRRUN,
     "lua_closethread returns the original error status");
  ok(lua_gettop(co) == 1 && lua_isstring(co, -1) &&
     strstr(lua_tostring(co, -1), "boom") != NULL,
     "lua_closethread keeps the original error object");
  lua_getglobal(L, "dead_closed");
  ok(lua_tointeger(L, -1) == 1, "lua_closethread closes the dead thread's slots");
  lua_pop(L, 2);

  /* A thread closed while it is suspended inside nested pcalls must start
  ** from a clean pcall nesting count when it is reused (PUC resets nCcalls
  ** in luaE_resetthread). Three rounds of 150 nested pcalls only fit below
  ** the bound of 200 if every close resets the count. */
  luaL_dostring(L,
    "function nest(n)\n"
    "  if n == 0 then coroutine.yield() return 0 end\n"
    "  local ok, v = pcall(nest, n - 1)\n"
    "  if not ok then error(v, 0) end\n"
    "  return v + 1\n"
    "end");
  {
    int i, nres, good = 1;
    co = lua_newthread(L);
    for (i = 0; i < 3; i++) {
      lua_getglobal(co, "nest");
      lua_pushinteger(co, 150);
      if (lua_resume(co, L, 1, &nres) != LUA_YIELD) good = 0;
      lua_closethread(co, L);
      lua_settop(co, 0);
    }
    ok(good, "lua_closethread resets the pcall nesting count");
    lua_pop(L, 1);
  }

  /* The count the __close handlers ran with (the closer's nesting plus one)
  ** must not stay on the thread: a reset thread has the pcall depth of a new
  ** one, whoever closed it and from whatever nesting. */
  luaL_dostring(L,
    "function depthprobe()\n"
    "  local d = 0\n"
    "  local function rec() d = d + 1; pcall(rec) end\n"
    "  pcall(rec)\n"
    "  return d\n"
    "end\n"
    "function closer_at(n, f, co)\n"
    "  if n == 0 then f(co) return end\n"
    "  pcall(closer_at, n - 1, f, co)\n"
    "end");
  {
    int nres;
    lua_Integer fresh, d;
    lua_State *fr = lua_newthread(L);
    fresh = thread_depth(L, fr);
    ok(fresh > 100, "closethread: a new thread has the full pcall depth");

    co = lua_newthread(L);
    lua_getglobal(co, "nest"); lua_pushinteger(co, 10);
    ok(lua_resume(co, L, 1, &nres) == LUA_YIELD, "closethread: suspended in pcalls");
    lua_closethread(co, NULL);
    d = thread_depth(L, co);
    ok(d == fresh, "lua_closethread(co, NULL): reset thread has the full pcall depth");

    lua_getglobal(co, "nest"); lua_pushinteger(co, 10);
    ok(lua_resume(co, L, 1, &nres) == LUA_YIELD, "closethread: suspended again");
    lua_getglobal(L, "closer_at");
    lua_pushinteger(L, 100);
    lua_pushcfunction(L, l_closefrom);
    lua_pushthread(co); lua_xmove(co, L, 1);
    ok(lua_pcall(L, 3, 0, 0) == LUA_OK, "closethread: closed from 100 nested pcalls");
    d = thread_depth(L, co);
    ok(d == fresh, "lua_closethread(co, from): closer's nesting does not stay on the thread");

    lua_getglobal(co, "nest"); lua_pushinteger(co, 10);
    ok(lua_resume(co, L, 1, &nres) == LUA_YIELD, "closethread: suspended a third time");
    lua_getglobal(L, "closer_at");
    lua_pushinteger(L, 100);
    lua_getglobal(L, "coroutine"); lua_getfield(L, -1, "close"); lua_remove(L, -2);
    lua_pushthread(co); lua_xmove(co, L, 1);
    ok(lua_pcall(L, 3, 0, 0) == LUA_OK, "coroutine.close from 100 nested pcalls");
    d = thread_depth(L, co);
    ok(d == fresh, "coroutine.close: closer's nesting does not stay on the thread");
    lua_pop(L, 2);
  }

  {
    int top = lua_gettop(L);
    luaopen_coroutine(L);  /* direct call: lua_call would normalize to one */
    ok(lua_gettop(L) == top+1, "luaopen_coroutine leaves one value");
  }
  ok(lua_istable(L, -1), "luaopen_coroutine returns a table");
  lua_getfield(L, -1, "create");
  ok(lua_isfunction(L, -1), "luaopen_coroutine table has create");
  lua_pop(L, 2);
  lua_close(L);
  {
    lua_State *L2 = luaL_newstate();  /* no luaL_openlibs: fallback path */
    luaopen_coroutine(L2);  /* direct call on a fresh state */
    ok(lua_gettop(L2) == 1, "luaopen_coroutine leaves one value on a fresh state");
    ok(lua_istable(L2, -1), "luaopen_coroutine installs base on demand");
    lua_getfield(L2, -1, "resume");
    ok(lua_isfunction(L2, -1), "on-demand coroutine table has resume");
    lua_close(L2);
  }
}

static void test_lauxlib54(void)
{
  lua_State *L = newL();
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addgsub(&b, "a-b-b", "b", "X");
  luaL_pushresult(&b);
  ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "a-X-X") == 0,
     "luaL_addgsub replaces all occurrences");
  lua_pop(L, 1);
  luaL_buffinit(L, &b);
  luaL_addstring(&b, "abcdef");
  luaL_buffsub(&b, 2);
  luaL_pushresult(&b);
  ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "abcd") == 0,
     "luaL_buffsub removes the tail");
  lua_pop(L, 1);
  luaL_pushfail(L);
  ok(lua_isnil(L, -1), "luaL_pushfail pushes nil");
  lua_pop(L, 1);
  /* lua_setcstacklimit is a deprecated no-op in PUC 5.4.9: it always returns
  ** LUAI_MAXCCALLS (200) and ignores the requested limit. */
  ok(lua_setcstacklimit(L, 0) == 200,
     "lua_setcstacklimit(0) returns 200 (PUC no-op)");
  ok(lua_setcstacklimit(L, 5) == 200,
     "lua_setcstacklimit(5) keeps returning 200");
  ok(lua_setcstacklimit(L, 1000000) == 200,
     "lua_setcstacklimit(1000000) keeps returning 200");
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

static void test_bare_state(void)
{
  /* A state with no standard library must still load and run chunks that name
  ** globals. The 5.4 lexical _ENV special case reads the interned "_ENV"
  ** string from gcroot[GCROOT_ENVSTR] while parsing (lj_parse.c var_lookup)
  ** and while recording (lj_record.c BC_GGET/GSET); luaopen_base used to
  ** install it, so a bare luaL_newstate() + luaL_dostring(L, "x = 1") crashed
  ** in var_lookup. PUC 5.4.9 runs the same chunk fine. */
  {
    lua_State *L = luaL_newstate();  /* deliberately no luaL_openlibs */
    int rc = luaL_dostring(L,
      "x = 1\n"
      "y = x + 2\n"
      "local s = 0\n"
      "for i = 1, 10 do s = s + x end\n"
      "z = s\n");
    ok(rc == LUA_OK, "bare state: chunk with global read/write/loop runs");
    if (rc != LUA_OK) printf("     error: %s\n", lua_tostring(L, -1));
    lua_getglobal(L, "y");
    ok(lua_tointeger(L, -1) == 3, "bare state: global written by chunk is visible");
    lua_pop(L, 1);
    lua_getglobal(L, "z");
    ok(lua_tointeger(L, -1) == 10, "bare state: loop over a global yields the right value");
    lua_pop(L, 1);
    lua_close(L);
  }
  {
    /* Only the string library: global access must not depend on luaopen_base. */
    lua_State *L = luaL_newstate();
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    lua_pop(L, 1);
    int rc = luaL_dostring(L, "a = ('x'):rep(3)\nb = a .. 'y'\n");
    ok(rc == LUA_OK, "string-only state: chunk with a global write runs");
    if (rc != LUA_OK) printf("     error: %s\n", lua_tostring(L, -1));
    lua_getglobal(L, "b");
    ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "xxxy") == 0,
       "string-only state: string method + global read work");
    lua_pop(L, 1);
    lua_close(L);
  }
  {
    /* C API global access on a bare state, both directions. */
    lua_State *L = luaL_newstate();
    lua_pushinteger(L, 42);
    lua_setglobal(L, "answer");
    lua_getglobal(L, "answer");
    ok(lua_tointeger(L, -1) == 42, "bare state: lua_setglobal/lua_getglobal round-trip");
    lua_pop(L, 1);
    int rc = luaL_dostring(L, "cseen = answer + 1\nfromlua = 7\n");
    ok(rc == LUA_OK, "bare state: chunk reads a C-set global");
    lua_getglobal(L, "cseen");
    ok(lua_tointeger(L, -1) == 43, "bare state: C-set global value crosses into Lua");
    lua_pop(L, 1);
    lua_getglobal(L, "fromlua");
    ok(lua_tointeger(L, -1) == 7, "bare state: Lua-set global crosses back to the C API");
    lua_pop(L, 1);
    lua_close(L);
  }
  {
    /* The JIT recorder reads gcroot[GCROOT_ENVSTR] on every GGET/GSET; a hot
    ** global loop on a bare state must compile a trace, not abort or crash. */
    lua_State *L = luaL_newstate();
    /* Open only the jit library. luaopen_jit is not a 5.4 luaL_requiref
    ** library (its return value is not the jit table), so register it the way
    ** luaL_openlibs does. */
    lua_pushcfunction(L, luaopen_jit);
    lua_pushstring(L, LUA_JITLIBNAME);
    lua_call(L, 1, 0);
    lua_getglobal(L, "jit");
    ok(lua_istable(L, -1), "bare state: jit library registers its table");
    lua_pop(L, 1);
    int rc = luaL_dostring(L,
      "jit.on()\n"
      "local n = 0\n"
      "jit.attach(function(what) if what == 'start' then n = n + 1 end end, 'trace')\n"
      "g = 0\n"
      "for i = 1, 2000 do g = g + i end\n"
      "traces = n\n"
      "result = g\n");
    ok(rc == LUA_OK, "bare state + jit: hot global loop runs");
    if (rc != LUA_OK) printf("     error: %s\n", lua_tostring(L, -1));
    lua_getglobal(L, "result");
    ok(lua_tointeger(L, -1) == 2001000, "bare state + jit: hot loop result is correct");
    lua_pop(L, 1);
    lua_getglobal(L, "traces");
    ok(lua_tointeger(L, -1) > 0, "bare state + jit: hot global loop compiled a trace");
    lua_pop(L, 1);
    lua_close(L);
  }
}

static const char *only;  /* CAPI_ONLY=<name>: run a single group (review of the
                          ** old commit needs the groups one by one, because a
                          ** panic in one aborts the process) */
static int want(const char *name)
{
  return only == NULL || strcmp(only, name) == 0;
}

int main(void)
{
  only = getenv("CAPI_ONLY");
  if (want("absindex")) test_absindex();
  if (want("getseti")) test_getseti();
  if (want("stream")) test_stream_abi();
  if (want("surface")) test_api54_surface();
  if (want("len")) test_len();
  if (want("compare")) test_compare();
  if (want("stringtonumber")) test_stringtonumber();
  if (want("getsubtable")) test_getsubtable();
  if (want("isinteger")) test_isinteger();
  if (want("rotate")) test_rotate();
  if (want("userdata")) test_newuserdatauv();
  if (want("iuservalue")) test_iuservalue();
  if (want("warning")) test_warning();
  if (want("warnf")) test_warnf();
  if (want("resume")) test_resume54();
  if (want("continuations")) test_continuations();
  if (want("arith")) test_arith();
  if (want("buffer")) test_buffer_api();
  if (want("toclose")) test_toclose();
  if (want("closethread")) test_closethread();
  if (want("oom_pcall")) test_oom_pcall();
  if (want("lauxlib")) test_lauxlib54();
  if (want("bare_state")) test_bare_state();
  printf("== capi: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
