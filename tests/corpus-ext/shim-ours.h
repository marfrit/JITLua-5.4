/* Build shim for the C-module corpus against OUR headers only (-include).
** Every definition here is a 5.4 C API name that src/lua.h, luaconf.h or
** lauxlib.h still lacks although LUA_VERSION_NUM says 504, so modules take
** their 5.4 code paths and fail to compile. The runner prints "shimmed" for
** each build so the gap stays visible; delete entries as the headers gain
** them (findings for the C API owner, 2026-11-16):
**   lua_rawlen (5.2 name of lua_objlen)        -- LPeg, lua-cjson
**   lua_getuservalue / lua_setuservalue         -- LPeg (ktable per pattern)
**   lua_Unsigned / LUA_UNSIGNED                 -- LPeg (utf8 ranges)
**   LUA_INTEGER_FMT / LUA_INTEGER_FRMLEN        -- lua-cjson (integer output)
**   luaL_Stream / LUA_FILEHANDLE                -- LuaFileSystem (lfs.lock on
**      a FILE* handle; our IOFileUD is {FILE *fp; uint32_t type}, the 5.4
**      layout is {FILE *f; lua_CFunction closef}: f coincides, closef does
**      not -- lfs.lock/unlock read garbage there, a library decision)
**   luaL_checkversion, lua_pushglobaltable      -- not hit yet, same family
*/
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#ifndef lua_rawlen
#define lua_rawlen(L, i)	lua_objlen(L, (i))
#endif
#ifndef lua_getuservalue
#define lua_getuservalue(L, i)	lua_getiuservalue(L, (i), 1)
#define lua_setuservalue(L, i)	lua_setiuservalue(L, (i), 1)
#endif
#ifndef LUA_UNSIGNED
#define LUA_UNSIGNED unsigned long long
typedef LUA_UNSIGNED lua_Unsigned;
#endif
#ifndef LUA_INTEGER_FMT
#define LUA_INTEGER_FRMLEN "ll"
#define LUA_INTEGER_FMT "%" LUA_INTEGER_FRMLEN "d"
#endif
#ifndef LUA_FILEHANDLE
#define LUA_FILEHANDLE "FILE*"
typedef struct luaL_Stream { FILE *f; lua_CFunction closef; } luaL_Stream;
#endif
