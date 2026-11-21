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

/* Lua 5.4: math.abs keeps integer values exact (mininteger stays mininteger). */
LJLIB_CF(math_abs)		LJLIB_REC(.)
{
  TValue *o = L->base;
  int64_t v;
  if (L->top > o && (tvisint(o) || tvisi64(o)) && lj_i64_getint(o, &v)) {
    lj_i64_toTValue(L, L->top-1, v < 0 ? (int64_t)((uint64_t)0 - (uint64_t)v) : v);
  } else {
    setnumV(L->top-1, fabs(lj_lib_checknum(L, 1)));
  }
  return 1;
}
/* Lua 5.4: floor/ceil return an integer when the result has an exact integer
** representation, otherwise the float. (C form: the asm fast function always
** produced a float, and fixing that in every backend is unnecessary.) */
static int math_round_result(lua_State *L, lua_Number r)
{
  int64_t k;
  if (lj_i64_numtoint(r, &k)) {  /* 2^63 is not an integer (saturating conv). */
    if ((int64_t)(int32_t)k == k) setintV(L->top++, (int32_t)k);
    else lj_i64_push(L, k);
  } else {
    setnumV(L->top++, r);
  }
  return 1;
}

/* An integer (int32, widened, boxed) is its own floor and ceil: never round
** it through a double (2^60+1 would lose the +1). */
static int math_round_int(lua_State *L)
{
  TValue *o = L->base;
  int64_t v;
  if (L->top > o && (tvisint(o) || tvisi64(o)) && lj_i64_getint(o, &v)) {
    copyTV(L, L->top-1, o);
    return 1;
  }
  return 0;
}

LJLIB_CF(math_floor)		LJLIB_REC(math_round IRFPM_FLOOR)
{
  if (math_round_int(L)) return 1;
  return math_round_result(L, floor(lj_lib_checknum(L, 1)));
}

LJLIB_CF(math_ceil)		LJLIB_REC(math_round IRFPM_CEIL)
{
  if (math_round_int(L)) return 1;
  return math_round_result(L, ceil(lj_lib_checknum(L, 1)));
}

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
LJLIB_ASM(math_atan)		LJLIB_REC(math_atan)
{
  lua_Number y = lj_lib_checknum(L, 1);
  lua_Number x;
  if (L->base+1 < L->top) {  /* 5.4: math.atan(y, x) is atan2(y, x) */
    x = lj_lib_checknum(L, 2);
    setnumV(L->base-1-LJ_FR2, atan2(y, x));
  } else {
    setnumV(L->base-1-LJ_FR2, atan(y));
  }
  return FFH_RES(1);
}
LJLIB_ASM_(math_sinh)		LJLIB_REC(math_call IRCALL_sinh)
LJLIB_ASM_(math_cosh)		LJLIB_REC(math_call IRCALL_cosh)
LJLIB_ASM_(math_tanh)		LJLIB_REC(math_call IRCALL_tanh)
LJLIB_ASM_(math_frexp)

/* 5.4 math.modf: an integer argument is its own integral part (fraction
** 0.0); otherwise the integral part is pushed as an integer when it fits
** (lmathlib pushnumint), the fraction as a float. C form: the asm fast
** function returned two floats. */
LJLIB_CF(math_modf)
{
  TValue *o = L->base;
  int64_t v;
  if (L->top > o && (tvisint(o) || tvisi64(o)) && lj_i64_getint(o, &v)) {
    copyTV(L, L->top, o); L->top++;
    setnumV(L->top++, 0.0);
    return 2;
  } else {
    lua_Number n = lj_lib_checknum(L, 1);
    lua_Number ip = (n < 0) ? ceil(n) : floor(n);
    lua_Number fp = (n == ip) ? 0.0 : (n - ip);
    if (n != n) { ip = n; fp = n; }  /* NaN: both parts NaN (lmathlib). */
    math_round_result(L, ip);  /* pushes one value */
    setnumV(L->top++, fp);
    return 2;
  }
}

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
/* Lua 5.4: math.fmod returns an integer for two integer arguments (C fmod
** semantics: the result takes the sign of the dividend), a float otherwise. */
LJLIB_CF(math_fmod)
{
  TValue *a = L->base, *b = L->base+1;
  if (L->top > b && (tvisint(a) || tvisi64(a)) && (tvisint(b) || tvisi64(b))) {
    int64_t x, y;
    if (lj_i64_getint(a, &x) && lj_i64_getint(b, &y)) {
      if (y == 0) lj_err_arg(L, 2, LJ_ERR_ARGZERO);  /* 5.4 lmathlib wording. */
      /* 5.4 (lmathlib): y == -1 gives 0 (avoids mininteger % -1). */
      lj_i64_toTValue(L, L->top-1, y == -1 ? 0 : (int64_t)(x % y));
      return 1;
    }
  }
  {
    lua_Number x = lj_lib_checknum(L, 1), y = lj_lib_checknum(L, 2);
    setnumV(L->top-1, fmod(x, y));
  }
  return 1;
}

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

static int math_minmax(lua_State *L, int ismax)
{
  /* PUC lmathlib math_min/math_max: lua_compare semantics on every argument,
  ** the winning argument is pushed unchanged (so its integer/float subtype
  ** survives), strings compare lexicographically, a numeric string next to a
  ** number raises PUC's compare error, and a tie keeps the earlier argument,
  ** including the first NaN and the first signed zero. */
  int i, n = (int)(L->top - L->base);
  int best = 1;
  luaL_argcheck(L, n >= 1, 1, "value expected");
  for (i = 2; i <= n; i++) {
    if (ismax ? lua_compare(L, best, i, LUA_OPLT)
	      : lua_compare(L, i, best, LUA_OPLT))
      best = i;
  }
  copyTV(L, L->base-1-LJ_FR2, L->base+best-1);
  return FFH_RES(1);
}

LJLIB_ASM(math_min)		LJLIB_REC(math_minmax IR_MIN)
{
  return math_minmax(L, 0);
}
LJLIB_ASM(math_max)		LJLIB_REC(math_minmax IR_MAX)
{
  return math_minmax(L, 1);
}

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

/* Push a 64-bit result as a 5.4 integer (ADR-001b: int32, widened or box). */
static void rand_pushuint(lua_State *L, uint64_t v)
{
  lj_i64_push(L, (int64_t)v);
}

/* JIT entry points (recff_math_random): the trace advances the very same
** xoshiro256** state the way the interpreter does, so a compiled loop yields
** the interpreter's sequence. The recorder guards low <= up beforehand. */
double lj_math_random_f(void *rs)
{
  return rand_2d(rand_next((RandState *)rs));
}

int64_t lj_math_random_0(void *rs)  /* math.random(0) */
{
  return (int64_t)TRIM64(rand_next((RandState *)rs));
}

int64_t lj_math_random_i(void *rs, int64_t low, int64_t up)
{
  uint64_t rv = rand_next((RandState *)rs);
  uint64_t p = rand_project(TRIM64(rv), (uint64_t)up - (uint64_t)low, (RandState *)rs);
  return (int64_t)(p + (uint64_t)low);
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
  /* 5.4 constants: exact 64-bit bounds as boxed integers (ADR-001b step 1).
  ** lj_lib_register leaves the library table on top; use that absolute index. */
  {
    int tabidx = lua_gettop(L);
    lua_pushstring(L, "maxinteger");
    lj_i64_push(L, (int64_t)0x7fffffffffffffffLL);
    lua_settable(L, tabidx);
    lua_pushstring(L, "mininteger");
    lj_i64_push(L, (int64_t)(-0x7fffffffffffffffLL - 1));
    lua_settable(L, tabidx);
  }
  return 1;
}

