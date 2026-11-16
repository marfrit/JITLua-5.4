/*
** OS library.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#include <errno.h>
#include <limits.h>
#include <time.h>

#define lib_os_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_lib.h"

#if LJ_TARGET_POSIX
#include <unistd.h>
#else
#include <stdio.h>
#endif

#if !LJ_TARGET_PSVITA
#include <locale.h>
#endif

/* ------------------------------------------------------------------------ */

#define LJLIB_MODULE_os

LJLIB_CF(os_execute)
{
#if LJ_NO_SYSTEM
#if LJ_52
  errno = ENOSYS;
  return luaL_fileresult(L, 0, NULL);
#else
  lua_pushinteger(L, -1);
  return 1;
#endif
#else
  const char *cmd = luaL_optstring(L, 1, NULL);
  int stat = system(cmd);
#if LJ_52
  if (cmd)
    return luaL_execresult(L, stat);
  setboolV(L->top++, 1);
#else
  setintV(L->top++, stat);
#endif
  return 1;
#endif
}

LJLIB_CF(os_remove)
{
  const char *filename = luaL_checkstring(L, 1);
  return luaL_fileresult(L, remove(filename) == 0, filename);
}

LJLIB_CF(os_rename)
{
  const char *fromname = luaL_checkstring(L, 1);
  const char *toname = luaL_checkstring(L, 2);
  /* 5.4: no filename prefix in the error message for rename. */
  return luaL_fileresult(L, rename(fromname, toname) == 0, NULL);
}

LJLIB_CF(os_tmpname)
{
#if LJ_TARGET_PS3 || LJ_TARGET_PS4 || LJ_TARGET_PS5 || LJ_TARGET_PSVITA || LJ_TARGET_NX || LJ_TARGET_IOS
  lj_err_caller(L, LJ_ERR_OSUNIQF);
  return 0;
#else
#if LJ_TARGET_POSIX
  char buf[15+1];
  int fp;
  strcpy(buf, "/tmp/lua_XXXXXX");
  fp = mkstemp(buf);
  if (fp != -1)
    close(fp);
  else
    lj_err_caller(L, LJ_ERR_OSUNIQF);
#else
  char buf[L_tmpnam];
  if (tmpnam(buf) == NULL)
    lj_err_caller(L, LJ_ERR_OSUNIQF);
#endif
  lua_pushstring(L, buf);
  return 1;
#endif
}

LJLIB_CF(os_getenv)
{
#if LJ_TARGET_CONSOLE
  lua_pushnil(L);
#else
  lua_pushstring(L, getenv(luaL_checkstring(L, 1)));  /* if NULL push nil */
#endif
  return 1;
}

LJLIB_CF(os_exit)
{
  int status;
  if (L->base < L->top && tvisbool(L->base))
    status = boolV(L->base) ? EXIT_SUCCESS : EXIT_FAILURE;
  else
    status = lj_lib_optint(L, 1, EXIT_SUCCESS);
  if (L->base+1 < L->top && tvistruecond(L->base+1))
    lua_close(L);
  exit(status);
  return 0;  /* Unreachable. */
}

LJLIB_CF(os_clock)
{
  setnumV(L->top++, ((lua_Number)clock())*(1.0/(lua_Number)CLOCKS_PER_SEC));
  return 1;
}

/* ------------------------------------------------------------------------ */

static void setfield(lua_State *L, const char *key, int value)
{
  lua_pushinteger(L, value);
  lua_setfield(L, -2, key);
}

static void setboolfield(lua_State *L, const char *key, int value)
{
  if (value < 0)  /* undefined? */
    return;  /* does not set field */
  lua_pushboolean(L, value);
  lua_setfield(L, -2, key);
}

static int getboolfield(lua_State *L, const char *key)
{
  int res;
  lua_getfield(L, -1, key);
  res = lua_isnil(L, -1) ? -1 : lua_toboolean(L, -1);
  lua_pop(L, 1);
  return res;
}

/* PUC 5.4 getfield: absent -> default (error when d<0), present but not an
** integer -> "field 'x' is not an integer", out-of-range -> out-of-bound. */
static int getfield(lua_State *L, const char *key, int d, int delta)
{
  int isnum, t;
  lua_Integer res;
  lua_getfield(L, -1, key);
  t = lua_type(L, -1);
  res = lua_tointegerx(L, -1, &isnum);
  if (!isnum) {
    if (t != LUA_TNIL)
      return luaL_error(L, "field " LUA_QS " is not an integer", key);
    else if (d < 0)
      return luaL_error(L, "field " LUA_QS " missing in date table", key);
    res = d;
  } else {
    if (!(res >= 0 ? res - delta <= INT_MAX : INT_MIN + delta <= res))
      return luaL_error(L, "field " LUA_QS " is out-of-bound", key);
    res -= delta;
  }
  lua_pop(L, 1);
  return (int)res;
}

/* 5.4: validate strftime conversion specifiers (C99 + POSIX E/O modifiers). */
#define LJ_STRFTIMEOPT1 "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%"
#define LJ_STRFTIMEOPT2 "EcECExEXEyEY" "OdOeOHOIOmOMOSOuOUOVOwOWOy"

static void os_checkdatefmt(lua_State *L, const char *s)
{
  const char *p;
  for (p = s; *p; p++) {
    char spec[4];
    if (*p != '%') continue;
    p++;
    spec[0] = '%';
    if (*p == '\0') {
      spec[1] = '\0';
      lj_err_argv(L, 1, LJ_ERR_OSDATEFMT, spec);
    }
    if (strchr(LJ_STRFTIMEOPT1, *p)) continue;
    spec[1] = *p;
    if ((*p == 'E' || *p == 'O') && p[1] != '\0') {
      char two[3];
      two[0] = p[0]; two[1] = p[1]; two[2] = '\0';
      if (strstr(LJ_STRFTIMEOPT2, two)) { p++; continue; }
      spec[2] = p[1];
      spec[3] = '\0';
      lj_err_argv(L, 1, LJ_ERR_OSDATEFMT, spec);
    }
    spec[2] = '\0';
    lj_err_argv(L, 1, LJ_ERR_OSDATEFMT, spec);
  }
}

LJLIB_CF(os_date)
{
  size_t slen;
  const char *s = luaL_optlstring(L, 1, "%c", &slen);
  const char *se;
  time_t t = lua_isnoneornil(L, 2) ? time(NULL) :
	     lj_num2int_type(luaL_checknumber(L, 2), time_t);
  struct tm *stm;
#if LJ_TARGET_POSIX
  struct tm rtm;
#endif
  se = s + slen;
  if (*s == '!') {  /* UTC? */
    s++;  /* Skip '!' */
#if LJ_TARGET_POSIX
    stm = gmtime_r(&t, &rtm);
#else
    stm = gmtime(&t);
#endif
  } else {
#if LJ_TARGET_POSIX
    stm = localtime_r(&t, &rtm);
#else
    stm = localtime(&t);
#endif
  }
  if (stm == NULL)  /* invalid date? */
    return luaL_error(L, "date result cannot be represented in this installation");
  if (se - s == 2 && s[0] == '*' && s[1] == 't') {
    lua_createtable(L, 0, 9);  /* 9 = number of fields */
    setfield(L, "sec", stm->tm_sec);
    setfield(L, "min", stm->tm_min);
    setfield(L, "hour", stm->tm_hour);
    setfield(L, "day", stm->tm_mday);
    setfield(L, "month", stm->tm_mon+1);
    setfield(L, "year", stm->tm_year+1900);
    setfield(L, "wday", stm->tm_wday+1);
    setfield(L, "yday", stm->tm_yday+1);
    setboolfield(L, "isdst", stm->tm_isdst);
  } else {
    /* PUC 5.4 formats piece by piece: literal bytes (including NULs) are
    ** copied, only conversion specifiers go through strftime. A single
    ** strftime on the whole format truncates at a NUL. */
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    while (s < se) {
      if (*s != '%') {
	luaL_addchar(&b, *s++);
      } else {
	char cc[4], tmp[256];
	char spec[4];
	size_t reslen;
	const char *p = s + 1;
	cc[0] = '%';
	spec[0] = '%';
	if (p >= se) {
	  spec[1] = '\0';
	  lj_err_argv(L, 1, LJ_ERR_OSDATEFMT, spec);
	}
	if (strchr(LJ_STRFTIMEOPT1, *p)) {
	  cc[1] = *p; cc[2] = '\0';
	  s = p + 1;
	} else if ((*p == 'E' || *p == 'O') && p+1 < se) {
	  char two[3];
	  two[0] = p[0]; two[1] = p[1]; two[2] = '\0';
	  if (!strstr(LJ_STRFTIMEOPT2, two)) {
	    spec[1] = p[0]; spec[2] = p[1]; spec[3] = '\0';
	    lj_err_argv(L, 1, LJ_ERR_OSDATEFMT, spec);
	  }
	  cc[1] = p[0]; cc[2] = p[1]; cc[3] = '\0';
	  s = p + 2;
	} else {
	  spec[1] = *p; spec[2] = '\0';
	  lj_err_argv(L, 1, LJ_ERR_OSDATEFMT, spec);
	}
	reslen = strftime(tmp, sizeof(tmp), cc, stm);
	luaL_addlstring(&b, tmp, reslen);
      }
    }
    luaL_pushresult(&b);
    lj_gc_check(L);
  }
  return 1;
}

LJLIB_CF(os_time)
{
  time_t t;
  errno = 0;
  if (lua_isnoneornil(L, 1)) {  /* called without args? */
    t = time(NULL);  /* get current time */
  } else {
    struct tm ts;
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_settop(L, 1);  /* make sure table is at the top */
    ts.tm_year = getfield(L, "year", -1, 1900);
    ts.tm_mon = getfield(L, "month", -1, 1);
    ts.tm_mday = getfield(L, "day", -1, 0);
    ts.tm_hour = getfield(L, "hour", 12, 0);
    ts.tm_min = getfield(L, "min", 0, 0);
    ts.tm_sec = getfield(L, "sec", 0, 0);
    ts.tm_isdst = getboolfield(L, "isdst");
    t = mktime(&ts);
    /* 5.4: update the table with normalized values. */
    setfield(L, "year", ts.tm_year+1900);
    setfield(L, "month", ts.tm_mon+1);
    setfield(L, "day", ts.tm_mday);
    setfield(L, "hour", ts.tm_hour);
    setfield(L, "min", ts.tm_min);
    setfield(L, "sec", ts.tm_sec);
    setfield(L, "yday", ts.tm_yday+1);
    setfield(L, "wday", ts.tm_wday+1);
    setboolfield(L, "isdst", ts.tm_isdst);
  }
  if (t == (time_t)(-1))
    return luaL_error(L, "time result cannot be represented in this installation");
  lua_pushinteger(L, (lua_Integer)t);  /* 5.4: os.time returns an integer */
  return 1;
}

LJLIB_CF(os_difftime)
{
  lua_pushnumber(L,
    difftime(lj_num2int_type(luaL_checknumber(L, 1), time_t),
	     lj_num2int_type(luaL_checknumber(L, 2), time_t)));
  return 1;
}

/* ------------------------------------------------------------------------ */

LJLIB_CF(os_setlocale)
{
#if LJ_TARGET_PSVITA
  lua_pushliteral(L, "C");
#else
  GCstr *s = lj_lib_optstr(L, 1);
  const char *str = s ? strdata(s) : NULL;
  int opt = lj_lib_checkopt(L, 2, 6,
    "\5ctype\7numeric\4time\7collate\10monetary\1\377\3all");
  if (opt == 0) opt = LC_CTYPE;
  else if (opt == 1) opt = LC_NUMERIC;
  else if (opt == 2) opt = LC_TIME;
  else if (opt == 3) opt = LC_COLLATE;
  else if (opt == 4) opt = LC_MONETARY;
  else if (opt == 6) opt = LC_ALL;
  lua_pushstring(L, setlocale(opt, str));
#endif
  return 1;
}

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_os(lua_State *L)
{
  LJ_LIB_REG(L, LUA_OSLIBNAME, os);
  return 1;
}

