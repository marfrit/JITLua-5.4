/*
** UTF-8 library for Lua 5.4 (MISSION P5.1).
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Adapted from the Lua 5.4.7 reference (lutf8lib.c).
** Copyright (C) 1994-2024 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lib_utf8_c
#define LUA_LIB

#include <limits.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_err.h"
#include "lj_lib.h"

#define LJLIB_MODULE_utf8

#define MAXUNICODE	0x10FFFFu
#define MAXUTF		0x7FFFFFFFu
#define UTF8_MSGINVALID	"invalid UTF-8 code"

typedef uint32_t utfint;
typedef size_t utf8_Unsigned;  /* unsigned counterpart of lua_Integer */

/* 5.4 luaL_pushfail pushes nil (no fail object in the C API). */
#define utf8_pushfail(L)	lua_pushnil(L)

#define iscont(c)	(((c) & 0xC0) == 0x80)
#define iscontp(p)	iscont(*(p))

/* Translate a relative string position: negative means back from end. */
static lua_Integer utf8_posrelat(lua_Integer pos, size_t len)
{
  if (pos >= 0) return pos;
  else if (0u - (size_t)pos > len) return 0;
  else return (lua_Integer)len + pos + 1;
}

/* Decode one UTF-8 sequence, returning NULL if the byte sequence is invalid.
** 'limits' holds the minimum value for each sequence length, to reject
** overlong representations.  The first entry forces an error for non-ASCII
** bytes with no continuation bytes (count == 0).
*/
static const char *utf8_decode(const char *s, utfint *val, int strict)
{
  static const utfint limits[] =
    { ~(utfint)0, 0x80, 0x800, 0x10000u, 0x200000u, 0x4000000u };
  unsigned int c = (unsigned char)s[0];
  utfint res = 0;
  if (c < 0x80) {  /* ASCII? */
    res = c;
  } else {
    int count = 0;
    for (; c & 0x40; c <<= 1) {  /* while it needs continuation bytes... */
      unsigned int cc = (unsigned char)s[++count];
      if (!iscont(cc)) return NULL;
      res = (res << 6) | (cc & 0x3F);
    }
    res |= ((utfint)(c & 0x7F) << (count * 5));
    if (count > 5 || res > MAXUTF || res < limits[count]) return NULL;
    s += count;
  }
  if (strict) {
    if (res > MAXUNICODE || (0xD800u <= res && res <= 0xDFFFu)) return NULL;
  }
  if (val) *val = res;
  return s + 1;
}

/* utf8.len(s [, i [, j [, lax]]]) */
LJLIB_CF(utf8_len)
{
  lua_Integer n = 0;
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  lua_Integer posi = utf8_posrelat(luaL_optinteger(L, 2, 1), len);
  lua_Integer posj = utf8_posrelat(luaL_optinteger(L, 3, -1), len);
  int lax = lua_toboolean(L, 4);
  luaL_argcheck(L, 1 <= posi && --posi <= (lua_Integer)len, 2,
		"initial position out of bounds");
  luaL_argcheck(L, --posj < (lua_Integer)len, 3,
		"final position out of bounds");
  while (posi <= posj) {
    const char *s1 = utf8_decode(s + posi, NULL, !lax);
    if (s1 == NULL) {
      utf8_pushfail(L);
      lua_pushinteger(L, posi + 1);
      return 2;
    }
    posi = (lua_Integer)(s1 - s);
    n++;
  }
  lua_pushinteger(L, n);
  return 1;
}

/* utf8.codepoint(s [, i [, j [, lax]]]) */
LJLIB_CF(utf8_codepoint)
{
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  lua_Integer posi = utf8_posrelat(luaL_optinteger(L, 2, 1), len);
  lua_Integer pose = utf8_posrelat(luaL_optinteger(L, 3, posi), len);
  int lax = lua_toboolean(L, 4);
  int n;
  const char *se;
  luaL_argcheck(L, posi >= 1, 2, "out of bounds");
  luaL_argcheck(L, pose <= (lua_Integer)len, 3, "out of bounds");
  if (posi > pose) return 0;
  if (pose - posi >= INT_MAX)
    return luaL_error(L, "string slice too long");
  n = (int)(pose - posi) + 1;
  luaL_checkstack(L, n, "string slice too long");
  n = 0;
  se = s + pose;
  for (s += posi - 1; s < se;) {
    utfint code;
    s = utf8_decode(s, &code, !lax);
    if (s == NULL) return luaL_error(L, UTF8_MSGINVALID);
    lua_pushinteger(L, (lua_Integer)code);
    n++;
  }
  return n;
}

/* Encode one code point as UTF-8 (up to 6 bytes for the MAXUTF range).
** Fills the buffer backwards, like the reference luaO_utf8esc. */
static void utf8_pushchar(lua_State *L, int arg)
{
  utf8_Unsigned code = (utf8_Unsigned)luaL_checkinteger(L, arg);
  char buf[8];
  unsigned int n = 1;
  luaL_argcheck(L, code <= MAXUTF, arg, "value out of range");
  if (code < 0x80) {
    buf[7] = (char)code;
  } else {
    unsigned int mfb = 0x3F;  /* maximum that fits in the first byte */
    do {
      buf[8 - (n++)] = (char)(0x80 | (code & 0x3F));
      code >>= 6;
      mfb >>= 1;
    } while (code > mfb);
    buf[8 - n] = (char)((~mfb << 1) | code);
  }
  lua_pushlstring(L, buf + 8 - n, (size_t)n);
}

/* utf8.char(n1, n2, ...) */
LJLIB_CF(utf8_char)
{
  int n = lua_gettop(L);
  if (n == 1) {
    utf8_pushchar(L, 1);
  } else {
    int i;
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    for (i = 1; i <= n; i++) {
      utf8_pushchar(L, i);
      luaL_addvalue(&b);
    }
    luaL_pushresult(&b);
  }
  return 1;
}

/* utf8.offset(s, n [, i]) */
LJLIB_CF(utf8_offset)
{
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  lua_Integer n = luaL_checkinteger(L, 2);
  lua_Integer posi = (n >= 0) ? 1 : (lua_Integer)len + 1;
  posi = utf8_posrelat(luaL_optinteger(L, 3, posi), len);
  luaL_argcheck(L, 1 <= posi && --posi <= (lua_Integer)len, 3,
		"position out of bounds");
  if (n == 0) {
    while (posi > 0 && iscontp(s + posi)) posi--;
  } else {
    if (iscontp(s + posi))
      return luaL_error(L, "initial position is a continuation byte");
    if (n < 0) {
      while (n < 0 && posi > 0) {
	do { posi--; } while (posi > 0 && iscontp(s + posi));
	n++;
      }
    } else {
      n--;
      while (n > 0 && posi < (lua_Integer)len) {
	do { posi++; } while (iscontp(s + posi));
	n--;
      }
    }
  }
  if (n == 0)
    lua_pushinteger(L, posi + 1);
  else
    utf8_pushfail(L);
  return 1;
}

static int utf8_iter_aux(lua_State *L, int strict)
{
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  utf8_Unsigned n = (utf8_Unsigned)lua_tointeger(L, 2);
  if (n < len) {
    while (iscontp(s + n)) n++;
  }
  if (n >= len) return 0;
  else {
    utfint code;
    const char *next = utf8_decode(s + n, &code, strict);
    if (next == NULL || iscontp(next))
      return luaL_error(L, UTF8_MSGINVALID);
    lua_pushinteger(L, (lua_Integer)(n + 1));
    lua_pushinteger(L, (lua_Integer)code);
    return 2;
  }
}

static int utf8_iter_strict(lua_State *L) { return utf8_iter_aux(L, 1); }
static int utf8_iter_lax(lua_State *L) { return utf8_iter_aux(L, 0); }

/* utf8.codes(s [, lax]) */
LJLIB_CF(utf8_codes)
{
  int lax = lua_toboolean(L, 2);
  const char *s = luaL_checkstring(L, 1);
  luaL_argcheck(L, !iscontp(s), 1, UTF8_MSGINVALID);
  lua_pushcfunction(L, lax ? utf8_iter_lax : utf8_iter_strict);
  lua_pushvalue(L, 1);
  lua_pushinteger(L, 0);
  return 3;
}

#define UTF8PATT	"[\0-\x7F\xC2-\xFD][\x80-\xBF]*"

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_utf8(lua_State *L)
{
  LJ_LIB_REG(L, LUA_UTF8LIBNAME, utf8);
  lua_pushlstring(L, UTF8PATT, sizeof(UTF8PATT)/sizeof(char) - 1);
  lua_setfield(L, -2, "charpattern");
  return 1;
}
