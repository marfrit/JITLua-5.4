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
  lua_pop(L, 1);  /* keep the table, pop the roundtrip result */
  /* int64 keys outside the inline forms: boxed exact, not a float. */
  {
    lua_Integer big = (lua_Integer)0x7fffffffffffffffLL;
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
  ok(lua_setcstacklimit(L, 200) == 200, "lua_setcstacklimit returns the previous limit (PUC 200)");
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
  test_absindex(); test_getseti(); test_stream_abi(); test_len(); test_compare();
  test_stringtonumber(); test_getsubtable(); test_isinteger(); test_rotate();
  test_newuserdatauv(); test_iuservalue(); test_warning(); test_warnf(); test_resume54(); test_lauxlib54();
  printf("== capi: %d checks, %d failures ==\n", checks, failures);
  return failures ? 1 : 0;
}
