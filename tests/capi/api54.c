/* Lua 5.4 signatures and formats of the C API: lua_load takes a mode,
** lua_dump takes a strip flag, lua_pushfstring knows '%I' (lua_Integer) and
** '%U' (a code point as UTF-8). Same source against JITLua-5.4 and PUC
** 5.4.9; the outputs must be identical (tests/capi/run.sh). */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

typedef struct { const char *s; size_t n; } Rd;
static const char *rd(lua_State *L, void *ud, size_t *sz)
{
  Rd *r = (Rd *)ud; (void)L;
  *sz = r->n; r->n = 0;
  return *sz ? r->s : NULL;
}

typedef struct { char b[65536]; size_t n; } Wr;
static int wr(lua_State *L, const void *p, size_t sz, void *ud)
{
  Wr *w = (Wr *)ud; (void)L;
  if (w->n + sz > sizeof(w->b)) return 1;
  memcpy(w->b + w->n, p, sz); w->n += sz;
  return 0;
}

static void hex(const char *tag, const char *s)
{
  printf("%s [", tag);
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c >= 32 && c < 127) putchar(c); else printf("\\x%02x", c);
  }
  printf("]\n");
}

static int f_err(lua_State *L)
{
  return luaL_error(L, "n=%I s=%s u=%U", (LUAI_UACINT)-5, "tail", (long)0x20AC);
}

static int load_mode(lua_State *L, const char *src, size_t n, const char *mode)
{
  Rd r; int st;
  r.s = src; r.n = n;
  st = lua_load(L, rd, &r, "=chunk", mode);
  if (st != LUA_OK) hex("  message", lua_tostring(L, -1));
  return st;
}

int main(void)
{
  lua_State *L = luaL_newstate();
  static Wr w0, w1;
  const char *src = "local a, b = ... return a + b + 40";
  const char *dsrc = "local a, b = ...\nlocal t = nil\nif a then return t.x end\nreturn 42";
  int st;
  luaL_openlibs(L);

  /* lua_pushfstring */
  hex("I", lua_pushfstring(L, "%I|%s|%d", (LUAI_UACINT)1234567890123LL, "str", 7));
  hex("I neg", lua_pushfstring(L, "%I %I %I", (LUAI_UACINT)-1,
			       (LUAI_UACINT)LUA_MININTEGER, (LUAI_UACINT)LUA_MAXINTEGER));
  hex("U", lua_pushfstring(L, "%U|%U|%U|%U|%U|%s", (long)0x41, (long)0xE9,
			   (long)0x20AC, (long)0x1F600, (long)0x7FFFFFFF, "end"));
  hex("mix", lua_pushfstring(L, "%d%%|%c|%f|%s|%I|%%I|%U%U", 3, 'x', 1.5, "s",
			     (LUAI_UACINT)42, (long)0x48, (long)0x49));
  hex("only", lua_pushfstring(L, "%I", (LUAI_UACINT)0));
  lua_settop(L, 0);
  lua_pushcfunction(L, f_err);
  st = lua_pcall(L, 0, 0, 0);
  printf("luaL_error st=%d ", st); hex("", lua_tostring(L, -1));
  lua_settop(L, 0);

  /* lua_load with a mode */
  st = load_mode(L, src, strlen(src), NULL); printf("text, mode NULL: %d\n", st);
  lua_settop(L, 0);
  st = load_mode(L, src, strlen(src), "t"); printf("text, mode t: %d\n", st);
  lua_settop(L, 0);
  st = load_mode(L, src, strlen(src), "bt"); printf("text, mode bt: %d\n", st);
  lua_settop(L, 0);
  st = load_mode(L, src, strlen(src), "b"); printf("text, mode b: %d\n", st);
  lua_settop(L, 0);

  /* lua_dump with a strip flag */
  luaL_loadbufferx(L, dsrc, strlen(dsrc), "@dumped.lua", NULL);
  w0.n = w1.n = 0;
  st = lua_dump(L, wr, &w0, 0); printf("dump: %d\n", st);
  st = lua_dump(L, wr, &w1, 1); printf("dump strip: %d smaller=%d top=%d\n", st,
				       w1.n < w0.n, lua_gettop(L));
  lua_settop(L, 0);
  st = load_mode(L, w0.b, w0.n, "b"); printf("binary, mode b: %d\n", st);
  if (st == LUA_OK) { lua_call(L, 0, 1); printf("  result %d\n", (int)lua_tointeger(L, -1)); }
  lua_settop(L, 0);
  st = load_mode(L, w0.b, w0.n, "t"); printf("binary, mode t: %d\n", st);
  lua_settop(L, 0);
  st = load_mode(L, w0.b, w0.n, NULL); printf("binary, mode NULL: %d\n", st);
  if (st == LUA_OK) {
    lua_pushboolean(L, 1);
    st = lua_pcall(L, 1, 1, 0);
    printf("  full debug info: %d line=%d\n", st,
	   strstr(lua_tostring(L, -1), "dumped.lua:3:") != NULL);
  }
  lua_settop(L, 0);
  st = load_mode(L, w1.b, w1.n, "b"); printf("stripped, mode b: %d\n", st);
  if (st == LUA_OK) {
    lua_pushboolean(L, 1);
    st = lua_pcall(L, 1, 1, 0);
    printf("  no debug info: %d line=%d\n", st,
	   strstr(lua_tostring(L, -1), "dumped.lua:3:") != NULL);
  }
  lua_settop(L, 0);
  lua_close(L);
  return 0;
}
