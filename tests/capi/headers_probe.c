/*
** Public-header compatibility probe for JITLua-5.4.
**
** This file deliberately does NOT include <limits.h>, <stdint.h> or
** <stddef.h>: every macro and type used here must come transitively from the
** public headers lua.h/lauxlib.h/lualib.h (like PUC 5.4.9's headers provide
** them).  It is built as a loadable module and exercised by
** tests/capi/headers_probe.lua; run.sh does both.
*/
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* <limits.h> must be pulled in by luaconf.h (PUC does the same). */
#if !defined(INT_MAX) || !defined(LONG_MAX) || !defined(LLONG_MAX)
#error "luaconf.h must include <limits.h> (INT_MAX/LONG_MAX/LLONG_MAX)"
#endif

/* Integer limits and the number-to-integer rule (PUC luaconf.h). */
#if !defined(LUA_MAXINTEGER) || !defined(LUA_MININTEGER) || !defined(LUA_MAXUNSIGNED)
#error "LUA_MAXINTEGER/LUA_MININTEGER/LUA_MAXUNSIGNED missing"
#endif
#if !defined(lua_numbertointeger)
#error "lua_numbertointeger missing"
#endif

/* Tunables and buffer/id sizes. */
#if !defined(LUAI_MAXSTACK)
#error "LUAI_MAXSTACK missing"
#endif
#if !defined(LUA_IDSIZE)
#error "LUA_IDSIZE missing"
#endif
#if !defined(LUAL_BUFFERSIZE)
#error "LUAL_BUFFERSIZE missing"
#endif
#if !defined(LUAL_NUMSIZES)
#error "LUAL_NUMSIZES missing"
#endif

/* Registry/global-name constants. */
#if !defined(LUA_GNAME) || !defined(LUA_PRELOAD_TABLE)
#error "LUA_GNAME/LUA_PRELOAD_TABLE missing"
#endif
#if !defined(LUA_NUMTYPES) || !defined(LUA_NUMTAGS)
#error "LUA_NUMTYPES/LUA_NUMTAGS missing"
#endif

/* Continuation context type and branch-prediction helpers. */
#if !defined(luai_likely) || !defined(luai_unlikely)
#error "luai_likely/luai_unlikely missing"
#endif
#if !defined(LUAMOD_API)
#error "LUAMOD_API missing"
#endif

static LUA_KCONTEXT probe_ctx;  /* must be a usable type */

static int probe_constants(lua_State *L)
{
  LUA_KCONTEXT ctx = probe_ctx;
  lua_createtable(L, 0, 16);
  lua_pushinteger(L, (lua_Integer)LUA_MAXINTEGER);
  lua_setfield(L, -2, "maxinteger");
  lua_pushinteger(L, (lua_Integer)LUA_MININTEGER);
  lua_setfield(L, -2, "mininteger");
  lua_pushboolean(L, ((LUA_UNSIGNED)LUA_MAXUNSIGNED) + 1 == 0);
  lua_setfield(L, -2, "maxunsigned_wraps");
  lua_pushinteger(L, (lua_Integer)INT_MAX);       /* <limits.h>, transitive */
  lua_setfield(L, -2, "int_max");
  lua_pushinteger(L, (lua_Integer)LONG_MAX);      /* <limits.h>, transitive */
  lua_setfield(L, -2, "long_max");
  lua_pushinteger(L, (lua_Integer)LUAI_MAXSTACK);
  lua_setfield(L, -2, "maxstack");
  lua_pushinteger(L, (lua_Integer)LUA_IDSIZE);
  lua_setfield(L, -2, "idsize");
  lua_pushinteger(L, (lua_Integer)LUAL_BUFFERSIZE);
  lua_setfield(L, -2, "bufsize");
  lua_pushinteger(L, (lua_Integer)LUAL_NUMSIZES);
  lua_setfield(L, -2, "numsizes");
  lua_pushinteger(L, (lua_Integer)LUAL_ABISTAMP);
  lua_setfield(L, -2, "abistamp");
  lua_pushinteger(L, (lua_Integer)LUAL_NUMABI);
  lua_setfield(L, -2, "numabi");
  lua_pushinteger(L, (lua_Integer)LUA_NUMTYPES);
  lua_setfield(L, -2, "numtypes");
  lua_pushstring(L, LUA_GNAME);
  lua_setfield(L, -2, "gname");
  lua_pushstring(L, LUA_PRELOAD_TABLE);
  lua_setfield(L, -2, "preload");
  lua_pushboolean(L, luai_likely(1) && !luai_unlikely(0));
  lua_setfield(L, -2, "likely");
  lua_pushboolean(L, ctx == (LUA_KCONTEXT)0);
  lua_setfield(L, -2, "kctx_zero");
  return 1;
}

static int probe_numbertointeger(lua_State *L)
{
  lua_Number n = luaL_checknumber(L, 1);
  lua_Integer i = 0;
  if (lua_numbertointeger(n, &i))
    lua_pushinteger(L, i);
  else
    lua_pushnil(L);
  return 1;
}

/* The conversion macros are text: a module only finds out that one of them
** is broken when it expands it. <stdio.h>, <stdlib.h> and <locale.h> are the
** user's job, exactly as with PUC. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>

static int probe_conversions(lua_State *L)
{
  char buf[LUAI_MAXNUMBER2STR + 32];
  char small[4];
  char *end;
  int n;
  lua_createtable(L, 0, 10);
  n = lua_integer2str(buf, sizeof(buf), (lua_Integer)-1234567890123LL);
  lua_pushlstring(L, buf, (size_t)n);
  lua_setfield(L, -2, "integer2str");
  n = lua_integer2str(small, sizeof(small), (lua_Integer)123456);
  lua_pushboolean(L, n == 6 && strcmp(small, "123") == 0);  /* bounded */
  lua_setfield(L, -2, "integer2str_bounded");
  n = lua_number2str(buf, sizeof(buf), (lua_Number)0.5);
  lua_pushlstring(L, buf, (size_t)n);
  lua_setfield(L, -2, "number2str");
  n = lua_number2str(small, sizeof(small), (lua_Number)123456.0);
  lua_pushboolean(L, n == 6 && strcmp(small, "123") == 0);
  lua_setfield(L, -2, "number2str_bounded");
  n = lua_number2strx(L, buf, sizeof(buf), "%.3f", (lua_Number)1.5);
  lua_pushlstring(L, buf, (size_t)n);
  lua_setfield(L, -2, "number2strx");
  n = lua_pointer2str(buf, sizeof(buf), (void *)L);
  lua_pushboolean(L, n > 0 && (size_t)n == strlen(buf));
  lua_setfield(L, -2, "pointer2str");
  lua_pushnumber(L, lua_str2number("2.25rest", &end));
  lua_setfield(L, -2, "str2number");
  lua_pushstring(L, end);
  lua_setfield(L, -2, "str2number_end");
  lua_pushnumber(L, lua_strx2number("0x10", &end));
  lua_setfield(L, -2, "strx2number");
  buf[0] = (char)lua_getlocaledecpoint(); buf[1] = 0;
  lua_pushstring(L, buf);
  lua_setfield(L, -2, "decpoint");
  return 1;
}

/* luaL_checkversion_ with the caller's idea of version and type/ABI stamp. */
static int probe_checkversion(lua_State *L)
{
  lua_Number ver = luaL_optnumber(L, 1, (lua_Number)LUA_VERSION_NUM);
  size_t sz = (size_t)luaL_optinteger(L, 2, (lua_Integer)LUAL_NUMABI);
  luaL_checkversion_(L, ver, sz);
  luaL_checkversion(L);
  return 0;
}

static const luaL_Reg probelib[] = {
  { "conversions", probe_conversions },
  { "checkversion", probe_checkversion },
  { "constants", probe_constants },
  { "numbertointeger", probe_numbertointeger },
  { NULL, NULL }
};

int luaopen_headers_probe(lua_State *L)
{
  luaL_newlib(L, probelib);
  /* The limits must be usable in constant expressions. */
  lua_pushboolean(L, LUA_MININTEGER < 0 && LUA_MAXINTEGER > 0 &&
                     LUA_MAXINTEGER >= (lua_Integer)INT_MAX);
  lua_setfield(L, -2, "sane_limits");
  /* The stamp PUC 5.4's own lauxlib.h would pass. */
  lua_pushinteger(L, (lua_Integer)(sizeof(lua_Integer)*16 + sizeof(lua_Number)));
  lua_setfield(L, -2, "puc_numsizes");
  return 1;
}
