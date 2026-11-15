/*
** Math library.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#include <math.h>
#include <time.h>

#define lib_math_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_err.h"
#include "lj_lib.h"
#include "lj_vm.h"
#include "lj_prng.h"
#include "lj_i64.h"

/* ------------------------------------------------------------------------ */

#define LJLIB_MODULE_math

LJLIB_ASM(math_abs)		LJLIB_REC(.)
{
  lj_lib_checknumber(L, 1);
  return FFH_RETRY;
}
LJLIB_ASM_(math_floor)		LJLIB_REC(math_round IRFPM_FLOOR)
LJLIB_ASM_(math_ceil)		LJLIB_REC(math_round IRFPM_CEIL)

LJLIB_ASM(math_sqrt)		LJLIB_REC(math_unary IRFPM_SQRT)
{
  lj_lib_checknum(L, 1);
  return FFH_RETRY;
}
LJLIB_ASM_(math_log10)		LJLIB_REC(math_call IRCALL_log10)
LJLIB_ASM_(math_exp)		LJLIB_REC(math_call IRCALL_exp)
LJLIB_ASM_(math_sin)		LJLIB_REC(math_call IRCALL_sin)
LJLIB_ASM_(math_cos)		LJLIB_REC(math_call IRCALL_cos)
LJLIB_ASM_(math_tan)		LJLIB_REC(math_call IRCALL_tan)
LJLIB_ASM_(math_asin)		LJLIB_REC(math_call IRCALL_asin)
LJLIB_ASM_(math_acos)		LJLIB_REC(math_call IRCALL_acos)
LJLIB_ASM_(math_atan)		LJLIB_REC(math_call IRCALL_atan)
LJLIB_ASM_(math_sinh)		LJLIB_REC(math_call IRCALL_sinh)
LJLIB_ASM_(math_cosh)		LJLIB_REC(math_call IRCALL_cosh)
LJLIB_ASM_(math_tanh)		LJLIB_REC(math_call IRCALL_tanh)
LJLIB_ASM_(math_frexp)
LJLIB_ASM_(math_modf)

LJLIB_ASM(math_log)		LJLIB_REC(math_log)
{
  double x = lj_lib_checknum(L, 1);
  if (L->base+1 < L->top) {
    double y = lj_lib_checknum(L, 2);
#ifdef LUAJIT_NO_LOG2
    x = log(x); y = 1.0 / log(y);
#else
    x = lj_vm_log2(x); y = 1.0 / lj_vm_log2(y);
#endif
    setnumV(L->base-1-LJ_FR2, x*y);  /* Do NOT join the expression to x / y. */
    return FFH_RES(1);
  }
  return FFH_RETRY;
}

LJLIB_LUA(math_deg) /* function(x) return x * 57.29577951308232 end */
LJLIB_LUA(math_rad) /* function(x) return x * 0.017453292519943295 end */

LJLIB_ASM(math_atan2)		LJLIB_REC(.)
{
  lj_lib_checknum(L, 1);
  lj_lib_checknum(L, 2);
  return FFH_RETRY;
}
LJLIB_ASM_(math_pow)		LJLIB_REC(.)
LJLIB_ASM_(math_fmod)

LJLIB_ASM(math_ldexp)		LJLIB_REC(.)
{
  lj_lib_checknum(L, 1);
#if LJ_DUALNUM && !LJ_TARGET_X86ORX64
  lj_lib_checkint(L, 2);
#else
  lj_lib_checknum(L, 2);
#endif
  return FFH_RETRY;
}

LJLIB_ASM(math_min)		LJLIB_REC(math_minmax IR_MIN)
{
  int i = 0;
  do { lj_lib_checknumber(L, ++i); } while (L->base+i < L->top);
  return FFH_RETRY;
}
LJLIB_ASM_(math_max)		LJLIB_REC(math_minmax IR_MAX)

LJLIB_PUSH(3.14159265358979323846) LJLIB_SET(pi)
LJLIB_PUSH(1e310) LJLIB_SET(huge)

/* ------------------------------------------------------------------------ */

/* Lua 5.4 math.random: the reference uses 'xoshiro256**' (PUC-Lua 5.4
** lmathlib.c). LuaJIT's own PRNG (lj_prng.c, Tausworthe) stays for internal
** use; this library-local state reproduces the 5.4 sequence bit-for-bit, so a
** seeded program yields the same numbers as PUC-Lua with the same seed.
*/
typedef struct RandState {
  uint64_t s[4];
} RandState;

#define ROTL64(x, n)	(((x) << (n)) | ((x) >> (64 - (n))))
#define TRIM64(x)	((x) & 0xffffffffffffffffu)

static uint64_t rand_next(RandState *rs)
{
  uint64_t s0 = rs->s[0], s1 = rs->s[1];
  uint64_t s2 = rs->s[2] ^ s0;
  uint64_t s3 = rs->s[3] ^ s1;
  uint64_t res = ROTL64(s1 * 5, 7) * 9;
  rs->s[0] = s0 ^ s3;
  rs->s[1] = s1 ^ s2;
  rs->s[2] = s2 ^ (s1 << 17);
  rs->s[3] = ROTL64(s3, 45);
  return res;
}

/* Float in [0,1) from the top 53 bits, like 5.4's I2d (FIGS = 53). */
static lua_Number rand_2d(uint64_t x)
{
  int64_t sx = (int64_t)(TRIM64(x) >> 11);
  lua_Number res = (lua_Number)sx * (0.5 / ((uint64_t)1 << 52));
  if (sx < 0) res += 1.0;  /* correct the two's complement */
  return res;
}

static void rand_setseed(RandState *rs, uint64_t n1, uint64_t n2)
{
  int i;
  rs->s[0] = n1;
  rs->s[1] = 0xff;  /* avoid an all-zero state */
  rs->s[2] = n2;
  rs->s[3] = 0;
  for (i = 0; i < 16; i++) (void)rand_next(rs);  /* spread the seed */
}

/* Project a value into [0, n] without bias (5.4's project()). */
static uint64_t rand_project(uint64_t ran, uint64_t n, RandState *rs)
{
  if ((n & (n + 1)) == 0)  /* n+1 is a power of 2: no bias */
    return ran & n;
  {
    uint64_t lim = n;
    lim |= (lim >> 1); lim |= (lim >> 2); lim |= (lim >> 4);
    lim |= (lim >> 8); lim |= (lim >> 16); lim |= (lim >> 32);
    while ((ran &= lim) > n)
      ran = TRIM64(rand_next(rs));  /* outside [0..n]? try again */
    return ran;
  }
}

/* Push a 64-bit unsigned as an integer where the int32 value model allows.
** Wider results are pushed as a float instead of silently truncating until
** ADR-001 is decided. */
static void rand_pushuint(lua_State *L, uint64_t v)
{
  if (v <= 0x7fffffffu)
    setintV(L->top++, (int32_t)v);
  else
    setnumV(L->top++, (lua_Number)v);
}

LJLIB_PUSH(top-2)  /* Upvalue holds userdata with RandState. */
LJLIB_CF(math_random)		LJLIB_REC(.)
{
  int n = (int)(L->top - L->base);
  RandState *rs = (RandState *)(uddata(udataV(lj_lib_upvalue(L, 1))));
  uint64_t rv = rand_next(rs);
  lua_Integer low, up;
  uint64_t p;
  switch (n) {
  case 0:
    setnumV(L->top++, rand_2d(rv));  /* float in [0,1) */
    return 1;
  case 1:
    low = 1;
    up = luaL_checkinteger(L, 1);
    if (up == 0) {  /* math.random(0): a full-range random integer */
      rand_pushuint(L, TRIM64(rv));
      return 1;
    }
    break;
  case 2:
    low = luaL_checkinteger(L, 1);
    up = luaL_checkinteger(L, 2);
    break;
  default:
    return luaL_error(L, "wrong number of arguments");
  }
  luaL_argcheck(L, low <= up, 1, "interval is empty");
  p = rand_project(TRIM64(rv), (uint64_t)up - (uint64_t)low, rs);
  rand_pushuint(L, p + (uint64_t)low);  /* integer in [low, up] */
  return 1;
}

/* 5.4 math.randomseed returns the two seeds it used. */
LJLIB_PUSH(top-2)  /* Upvalue holds userdata with RandState. */
LJLIB_CF(math_randomseed)
{
  RandState *rs = (RandState *)(uddata(udataV(lj_lib_upvalue(L, 1))));
  uint64_t n1, n2;
  if (L->base == L->top) {  /* "random" seed: time and an address */
    n1 = (uint64_t)time(NULL);
    n2 = (uint64_t)(size_t)L;
  } else {
    n1 = (uint64_t)luaL_checkinteger(L, 1);
    n2 = (uint64_t)luaL_optinteger(L, 2, 0);
  }
  rand_setseed(rs, n1, n2);
  rand_pushuint(L, n1);
  rand_pushuint(L, n2);
  return 2;
}

/* -- Lua 5.4 additions (MISSION P5.5) ------------------------------------
** math.maxinteger/math.mininteger are deliberately absent until the int64
** value model lands (ADR-001): they cannot be represented exactly as doubles.
*/

LJLIB_CF(math_type)
{
  TValue *o = L->base;
  luaL_checkany(L, 1);
  if (tvisint(o))
    lua_pushstring(L, "integer");
  else if (tvisi64(o))
    lua_pushstring(L, "integer");  /* ADR-001b: boxed int64 is an integer */
  else if (tvisnum(o))
    lua_pushstring(L, "float");
  else
    lua_pushnil(L);  /* 5.4 returns fail for non-numbers */
  return 1;
}

LJLIB_CF(math_tointeger)
{
  int ok, isnum;
  lua_Integer n;
  lua_Number d;
  luaL_checkany(L, 1);
  n = lua_tointegerx(L, 1, &ok);
  /* 5.4: the value must have an exact integer representation (also for
  ** numeric strings, which lua_tointegerx would otherwise truncate). */
  d = lua_tonumberx(L, 1, &isnum);
  if (ok && (!isnum || (lua_Number)n != d))
    ok = 0;
  if (ok)
    lua_pushinteger(L, n);
  else
    lua_pushnil(L);
  return 1;
}

LJLIB_CF(math_ult)
{
  lua_Integer a = luaL_checkinteger(L, 1);
  lua_Integer b = luaL_checkinteger(L, 2);
  lua_pushboolean(L, (size_t)a < (size_t)b);  /* unsigned comparison */
  return 1;
}

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_math(lua_State *L)
{
  /* 5.4 random state: seed it like the reference (time + address). */
  RandState *rs = (RandState *)lua_newuserdata(L, sizeof(RandState));
  rand_setseed(rs, (uint64_t)time(NULL), (uint64_t)(size_t)L);
  LJ_LIB_REG(L, LUA_MATHLIBNAME, math);
  /* 5.4 math.maxinteger/mininteger need a 64-bit integer that Lua code can
  ** see. lj_i64_box() provides it (ADR-001b, C-test verified), but pushing it
  ** as a library constant crashes the interpreter's fast print/format path:
  ** measured this session (segfault in the VM for print(math.maxinteger)).
  ** Step 2 (parser/VM) must teach that path the box first, so the constants
  ** stay out until then. */
  return 1;
}

