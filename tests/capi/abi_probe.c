/*
** Source-vs-binary ABI probe for JITLua-5.4.
**
** The same source is built twice: against PUC 5.4.9's public headers and
** against JITLua's.  luaL_newlib() calls luaL_checkversion(), so the
** PUC-built module must be rejected when JITLua loads it (its pseudo-indices
** and luaL_Buffer layout would be wrong), while the JITLua-built module must
** load and work.  The module deliberately uses lua_upvalueindex() and
** LUA_REGISTRYINDEX: those are the two indices that differ between the
** headers, and a wrong value here would silently read the wrong slot.
*/
#include "lua.h"
#include "lauxlib.h"

#define PROBE_KEY "abi_probe.key"

static int probe_upvalue(lua_State *L)
{
  (void)L;
  lua_pushvalue(L, lua_upvalueindex(1));
  return 1;
}

static int probe_registry(lua_State *L)
{
  lua_getfield(L, LUA_REGISTRYINDEX, PROBE_KEY);
  return 1;
}

static const luaL_Reg probe_funcs[] = {
  { "upvalue", probe_upvalue },
  { "registry", probe_registry },
  { NULL, NULL }
};

LUAMOD_API int luaopen_abi_probe(lua_State *L)
{
  luaL_newlib(L, probe_funcs);  /* luaL_checkversion() happens here */
  lua_pushliteral(L, "upvalue-ok");
  lua_pushcclosure(L, probe_upvalue, 1);
  lua_setfield(L, -2, "upval");
  lua_pushliteral(L, "registry-ok");
  lua_setfield(L, LUA_REGISTRYINDEX, PROBE_KEY);
  return 1;
}
