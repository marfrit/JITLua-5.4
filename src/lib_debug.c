/*
** Debug library.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lib_debug_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_debug.h"
#include "lj_lib.h"
#include "lj_frame.h"
#include "lj_state.h"
#include "lj_trace.h"

/* ------------------------------------------------------------------------ */

#define LJLIB_MODULE_debug

LJLIB_CF(debug_getregistry)
{
  copyTV(L, L->top++, registry(L));
  return 1;
}

LJLIB_CF(debug_getmetatable)	LJLIB_REC(.)
{
  lj_lib_checkany(L, 1);
  if (!lua_getmetatable(L, 1)) {
    setnilV(L->top-1);
  }
  return 1;
}

LJLIB_CF(debug_setmetatable)
{
  lj_lib_checktabornil(L, 2);
  L->top = L->base+2;
  lua_setmetatable(L, 1);
#if !LJ_52
  setboolV(L->top-1, 1);
#endif
  return 1;
}

LJLIB_CF(debug_getfenv)
{
  lj_lib_checkany(L, 1);
  lua_getfenv(L, 1);
  return 1;
}

LJLIB_CF(debug_setfenv)
{
  lj_lib_checktab(L, 2);
  L->top = L->base+2;
  if (!lua_setfenv(L, 1))
    lj_err_caller(L, LJ_ERR_SETFENV);
  return 1;
}

/* ------------------------------------------------------------------------ */

static void settabss(lua_State *L, const char *i, const char *v)
{
  lua_pushstring(L, v);
  lua_setfield(L, -2, i);
}

static void settabsi(lua_State *L, const char *i, int v)
{
  lua_pushinteger(L, v);
  lua_setfield(L, -2, i);
}

static void settabsb(lua_State *L, const char *i, int v)
{
  lua_pushboolean(L, v);
  lua_setfield(L, -2, i);
}

static lua_State *getthread(lua_State *L, int *arg)
{
  if (L->base < L->top && tvisthread(L->base)) {
    *arg = 1;
    return threadV(L->base);
  } else {
    *arg = 0;
    return L;
  }
}

static void treatstackoption(lua_State *L, lua_State *L1, const char *fname)
{
  if (L == L1) {
    lua_pushvalue(L, -2);
    lua_remove(L, -3);
  }
  else
    lua_xmove(L1, L, 1);
  lua_setfield(L, -2, fname);
}

LJLIB_CF(debug_getinfo)
{
  lj_Debug ar;
  int arg, opt_f = 0, opt_L = 0;
  lua_State *L1 = getthread(L, &arg);
  const char *options = luaL_optstring(L, arg+2, "flnSrtu");
  /* 5.4 db_getinfo: room for the results on the other thread's stack, then
  ** a leading '>' is rejected before the function or level is looked at; it
  ** would make lua_getinfo take (and pop) a function from the stack of the
  ** inspected thread. A '>' later in the string is an invalid option. */
  if (L != L1 && !lua_checkstack(L1, 3))
    luaL_error(L, "stack overflow");
  if (options[0] == '>')
    luaL_argerror(L, arg+2, "invalid option '>'");
  /* 5.4 db_getinfo: a function is checked first; anything else is a stack
  ** level via luaL_checkinteger (so a table gives "number expected, got
  ** table" and 1.5 gives "number has no integer representation"). */
  if (L->base+arg < L->top && tvisfunc(L->base+arg)) {
    options = lua_pushfstring(L, ">%s", options);
    setfuncV(L1, L1->top++, funcV(L->base+arg));
  } else {
    int level = (int)luaL_checkinteger(L, arg+1);
    if (!lua_getstack(L1, level, (lua_Debug *)&ar)) {
      setnilV(L->top-1);
      return 1;
    }
  }
  ar.ftransfer = ar.ntransfer = 0;
  if (strchr(options, 'r') && hook_active(G(L))) {  /* Hook transfer info. */
    ar.ftransfer = (unsigned short)G(L)->hookftransfer;
    ar.ntransfer = (unsigned short)G(L)->hookntransfer;
  }
  if (!lj_debug_getinfo(L1, options, &ar, 1))
    lj_err_arg(L, arg+2, LJ_ERR_INVOPT);
  lua_createtable(L, 0, 16);  /* Create result table. */
  for (; *options; options++) {
    switch (*options) {
    case 'S':
      settabss(L, "source", ar.source);
      settabss(L, "short_src", ar.short_src);
      settabsi(L, "linedefined", ar.linedefined);
      settabsi(L, "lastlinedefined", ar.lastlinedefined);
      settabss(L, "what", ar.what);
      break;
    case 'l':
      settabsi(L, "currentline", ar.currentline);
      break;
    case 'u':
      settabsi(L, "nups", ar.nups);
      settabsi(L, "nparams", ar.nparams);
      settabsb(L, "isvararg", ar.isvararg);
      break;
    case 'n':
      settabss(L, "name", ar.name);
      settabss(L, "namewhat", ar.namewhat);
      break;
    case 't':
      settabsb(L, "istailcall", ar.istailcall);
      break;
    case 'r':
      settabsi(L, "ftransfer", ar.ftransfer);
      settabsi(L, "ntransfer", ar.ntransfer);
      break;
    case 'f': opt_f = 1; break;
    case 'L': opt_L = 1; break;
    default: break;
    }
  }
  if (opt_L) treatstackoption(L, L1, "activelines");
  if (opt_f) treatstackoption(L, L1, "func");
  return 1;  /* Return result table. */
}

LJLIB_CF(debug_getlocal)
{
  int arg;
  lua_State *L1 = getthread(L, &arg);
  lua_Debug ar;
  const char *name;
  int slot = lj_lib_checkint(L, arg+2);
  if (tvisfunc(L->base+arg)) {
    L->top = L->base+arg+1;
    lua_pushstring(L, lua_getlocal(L, NULL, slot));
    return 1;
  }
  if (!lua_getstack(L1, lj_lib_checkint(L, arg+1), &ar))
    lj_err_arg(L, arg+1, LJ_ERR_LVLRNG);
  name = lua_getlocal(L1, &ar, slot);
  if (name) {
    lua_xmove(L1, L, 1);
    lua_pushstring(L, name);
    lua_pushvalue(L, -2);
    return 2;
  } else {
    setnilV(L->top-1);
    return 1;
  }
}

LJLIB_CF(debug_setlocal)
{
  int arg;
  lua_State *L1 = getthread(L, &arg);
  lua_Debug ar;
  TValue *tv;
  if (!lua_getstack(L1, lj_lib_checkint(L, arg+1), &ar))
    lj_err_arg(L, arg+1, LJ_ERR_LVLRNG);
  tv = lj_lib_checkany(L, arg+3);
  copyTV(L1, L1->top++, tv);
  lua_pushstring(L, lua_setlocal(L1, &ar, lj_lib_checkint(L, arg+2)));
  return 1;
}

static int debug_getupvalue(lua_State *L, int get)
{
  int32_t n = lj_lib_checkint(L, 2);
  const char *name;
  lj_lib_checkfunc(L, 1);
  name = get ? lua_getupvalue(L, 1, n) : lua_setupvalue(L, 1, n);
  if (name) {
    lua_pushstring(L, name);
    if (!get) return 1;
    copyTV(L, L->top, L->top-2);
    L->top++;
    return 2;
  }
  return 0;
}

LJLIB_CF(debug_getupvalue)
{
  return debug_getupvalue(L, 1);
}

LJLIB_CF(debug_setupvalue)
{
  lj_lib_checkany(L, 3);
  return debug_getupvalue(L, 0);
}

LJLIB_CF(debug_upvalueid)
{
  GCfunc *fn = lj_lib_checkfunc(L, 1);
  int32_t n = lj_lib_checkint(L, 2) - 1;
  /* 5.4: an out-of-range index returns fail (nil), it does not raise. */
  if ((uint32_t)n >= lj_debug_nupvalues(fn)) {
    setnilV(L->top++);
    return 1;
  }
  lua_pushlightuserdata(L, lua_upvalueid(L, 1, n+1));
  return 1;
}

LJLIB_CF(debug_upvaluejoin)
{
  GCfunc *fn[2];
  int i;
  for (i = 0; i < 2; i++) {
    int32_t n;
    fn[i] = lj_lib_checkfunc(L, 2*i+1);
    if (!isluafunc(fn[i]))
      lj_err_arg(L, 2*i+1, LJ_ERR_NOLFUNC);
    n = lj_lib_checkint(L, 2*i+2) - 1;
    if ((uint32_t)n >= lj_debug_nupvalues(fn[i]))
      lj_err_arg(L, 2*i+2, LJ_ERR_UPVIDX);  /* 5.4 wording */
  }
  L->top = L->base+4;
  lua_upvaluejoin(L, 1, lj_lib_checkint(L, 2), 3, lj_lib_checkint(L, 4));
  return 0;
}

#if LJ_52
/* 5.4 debug.getuservalue(u, n): the n-th user value plus true, or fail. */
LJLIB_CF(debug_getuservalue)
{
  int n = (int)luaL_optinteger(L, 2, 1);
  if (!(L->base < L->top && tvisudata(L->base) && !tvisi64(L->base))) {
    lua_pushnil(L);  /* luaL_pushfail: a non-userdata is not an error. */
    return 1;
  }
  L->top = L->base+1;
  if (lua_getiuservalue(L, 1, n) != LUA_TNONE) {
    lua_pushboolean(L, 1);
    return 2;
  }
  return 1;
}

/* 5.4 debug.setuservalue(u, value, n): returns u, or fail if n is out of range. */
LJLIB_CF(debug_setuservalue)
{
  int n;
  if (!(L->base < L->top && tvisudata(L->base) && !tvisi64(L->base)))
    lj_err_argt(L, 1, LUA_TUSERDATA);
  luaL_checkany(L, 2);
  n = (int)luaL_optinteger(L, 3, 1);
  L->top = L->base+2;
  if (!lua_setiuservalue(L, 1, n))
    lua_pushnil(L);  /* luaL_pushfail */
  return 1;
}
#endif

/* ------------------------------------------------------------------------ */

#define KEY_HOOK	(U64x(81000000,00000000)|'h')

/* 5.4: hooks are per thread. The registry's "_HOOKKEY" table (weak keys, as
** in PUC) maps thread -> hook function; the KEY_HOOK table maps thread ->
** mask | count<<4. LuaJIT's hook machinery is global, so the installed mask
** is the union over all threads and hookf() filters by the running thread's
** own mask.
*/
static void hook_gettable(lua_State *L, int masks)
{
  if (masks) (L->top++)->u64 = KEY_HOOK; else lua_pushliteral(L, "_HOOKKEY");
  lua_rawget(L, LUA_REGISTRYINDEX);
}

static void hook_mktable(lua_State *L, int masks)
{
  hook_gettable(L, masks);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_createtable(L, 0, 2);
    lua_createtable(L, 0, 1);
    lua_pushliteral(L, "k");
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    if (masks) (L->top++)->u64 = KEY_HOOK; else lua_pushliteral(L, "_HOOKKEY");
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

static void hookf(lua_State *L, lua_Debug *ar)
{
  static const char *const hooknames[] =
    {"call", "return", "line", "count", "tail call"};
  int ev = (int)ar->event;
  int bit = ev == LUA_HOOKTAILCALL ? LUA_MASKCALL : (1 << ev);
  lua_Integer m;
  hook_gettable(L, 1);
  if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
  lua_pushthread(L);
  lua_rawget(L, -2);
  m = lua_tointeger(L, -1);
  lua_pop(L, 2);
  if (!(m & bit)) return;  /* Not an event this thread's hook asked for. */
  hook_gettable(L, 0);
  if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
  lua_pushthread(L);
  lua_rawget(L, -2);
  lua_remove(L, -2);
  if (lua_isfunction(L, -1)) {
    lua_pushstring(L, hooknames[ev]);
    if (ar->currentline >= 0)
      lua_pushinteger(L, ar->currentline);
    else lua_pushnil(L);
    lua_call(L, 2, 0);
  } else {
    lua_pop(L, 1);
  }
}

static int makemask(const char *smask, int count)
{
  int mask = 0;
  if (strchr(smask, 'c')) mask |= LUA_MASKCALL;
  if (strchr(smask, 'r')) mask |= LUA_MASKRET;
  if (strchr(smask, 'l')) mask |= LUA_MASKLINE;
  if (count > 0) mask |= LUA_MASKCOUNT;
  return mask;
}

static char *unmakemask(int mask, char *smask)
{
  int i = 0;
  if (mask & LUA_MASKCALL) smask[i++] = 'c';
  if (mask & LUA_MASKRET) smask[i++] = 'r';
  if (mask & LUA_MASKLINE) smask[i++] = 'l';
  smask[i] = '\0';
  return smask;
}

LJLIB_CF(debug_sethook)
{
  int arg, mask, count, umask = 0, ucount = 0;
  lua_State *L1 = getthread(L, &arg);
  if (lua_isnoneornil(L, arg+1)) {
    lua_settop(L, arg+1);
    mask = 0; count = 0;  /* turn off hooks */
  } else {
    const char *smask = luaL_checkstring(L, arg+2);
    luaL_checktype(L, arg+1, LUA_TFUNCTION);
    count = luaL_optint(L, arg+3, 0);
    mask = makemask(smask, count);
  }
  hook_mktable(L, 0);  /* _HOOKKEY[L1] = func */
  setthreadV(L, L->top, L1); incr_top(L);
  lua_pushvalue(L, arg+1);
  lua_rawset(L, -3);
  lua_pop(L, 1);
  hook_mktable(L, 1);  /* KEY_HOOK[L1] = mask | count<<4 */
  setthreadV(L, L->top, L1); incr_top(L);
  if (mask) lua_pushinteger(L, (lua_Integer)mask | ((lua_Integer)count << 4));
  else lua_pushnil(L);
  lua_rawset(L, -3);
  lua_pushnil(L);  /* Union of all threads' masks, smallest count. */
  while (lua_next(L, -2)) {
    lua_Integer m = lua_tointeger(L, -1);
    int c = (int)(m >> 4);
    umask |= (int)(m & HOOK_EVENTMASK);
    if (c > 0 && (ucount == 0 || c < ucount)) ucount = c;
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
#if LJ_HASJIT
  /* 5.4: a hook must fire inside loops that are already compiled -- flush
  ** the traces (the patched loop bytecodes revert to the interpreter) and
  ** the dispatch update below keeps the JIT out while the hook is set. */
  if (umask) lj_trace_flushall(L);
#endif
  lua_sethook(L, umask ? hookf : NULL, umask, ucount);
  /* PUC lua_sethook sets oldpc to the current instruction: the line that
  ** called debug.sethook gets no line event of its own. Our reference is
  ** the pc saved in the C frame, which is stale until the first dispatch. */
  if (umask && frame_islua(L->base-1) && L->cframe)
    setcframe_pc(cframe_raw(L->cframe), frame_pc(L->base-1));
  return 0;
}

LJLIB_CF(debug_gethook)
{
  char buff[5];
  int arg, mask, count;
  lua_State *L1 = getthread(L, &arg);
  lua_Hook hook = lua_gethook(L);
  lua_Integer m;
  if (hook != NULL && hook != hookf) {  /* external hook? */
    lua_pushliteral(L, "external hook");
    lua_pushstring(L, unmakemask(lua_gethookmask(L), buff));
    lua_pushinteger(L, lua_gethookcount(L));
    return 3;
  }
  hook_gettable(L, 0);
  if (lua_istable(L, -1)) {
    setthreadV(L, L->top, L1); incr_top(L);
    lua_rawget(L, -2);
    lua_remove(L, -2);
  }
  if (lua_isnil(L, -1)) return 1;  /* No hook for this thread. */
  hook_gettable(L, 1);
  setthreadV(L, L->top, L1); incr_top(L);
  lua_rawget(L, -2);
  m = lua_tointeger(L, -1);
  lua_pop(L, 2);
  mask = (int)(m & HOOK_EVENTMASK);
  count = (int)(m >> 4);
  lua_pushstring(L, unmakemask(mask, buff));
  lua_pushinteger(L, count);
  return 3;
}

/* ------------------------------------------------------------------------ */

LJLIB_CF(debug_debug)
{
  for (;;) {
    char buffer[250];
    fputs("lua_debug> ", stderr);
    if (fgets(buffer, sizeof(buffer), stdin) == 0 ||
	strcmp(buffer, "cont\n") == 0)
      return 0;
    if (luaL_loadbuffer(L, buffer, strlen(buffer), "=(debug command)") ||
	lua_pcall(L, 0, 0, 0)) {
      const char *s = lua_tostring(L, -1);
      fputs(s ? s : "(error object is not a string)", stderr);
      fputs("\n", stderr);
    }
    lua_settop(L, 0);  /* remove eventual returns */
  }
}

/* ------------------------------------------------------------------------ */

#define LEVELS1	12	/* size of the first part of the stack */
#define LEVELS2	10	/* size of the second part of the stack */

LJLIB_CF(debug_traceback)
{
  int arg;
  lua_State *L1 = getthread(L, &arg);
  const char *msg = lua_tostring(L, arg+1);
  /* 5.4: a message that is neither a string nor nil is returned untouched;
  ** nil is no message, also with a level after it. */
  if (msg == NULL && L->top > L->base+arg && !tvisnil(L->base+arg))
    L->top = L->base+arg+1;
  else
    luaL_traceback(L, L1, msg, lj_lib_optint(L, arg+2, (L == L1)));
  return 1;
}

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_debug(lua_State *L)
{
  LJ_LIB_REG(L, LUA_DBLIBNAME, debug);
  return 1;
}

