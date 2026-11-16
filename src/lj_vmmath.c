/*
** Math helper functions for assembler VM.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#define lj_vmmath_c
#define LUA_CORE

#include <errno.h>
#include <math.h>

#include "lj_obj.h"
#include "lj_ir.h"
#include "lj_vm.h"

#if LJ_TARGET_X86
int64_t (*lj_vm_num2i64_ptr)(double x) = lj_vm_num2i64;
uint64_t (*lj_vm_num2u64_ptr)(double x) = lj_vm_num2u64;
#endif

/* -- Wrapper functions --------------------------------------------------- */

#if LJ_TARGET_X86 && __ELF__ && __PIC__
/* Wrapper functions to deal with the ELF/x86 PIC disaster. */
LJ_FUNCA double lj_wrap_log(double x) { return log(x); }
LJ_FUNCA double lj_wrap_log10(double x) { return log10(x); }
LJ_FUNCA double lj_wrap_exp(double x) { return exp(x); }
LJ_FUNCA double lj_wrap_sin(double x) { return sin(x); }
LJ_FUNCA double lj_wrap_cos(double x) { return cos(x); }
LJ_FUNCA double lj_wrap_tan(double x) { return tan(x); }
LJ_FUNCA double lj_wrap_asin(double x) { return asin(x); }
LJ_FUNCA double lj_wrap_acos(double x) { return acos(x); }
LJ_FUNCA double lj_wrap_atan(double x) { return atan(x); }
LJ_FUNCA double lj_wrap_sinh(double x) { return sinh(x); }
LJ_FUNCA double lj_wrap_cosh(double x) { return cosh(x); }
LJ_FUNCA double lj_wrap_tanh(double x) { return tanh(x); }
LJ_FUNCA double lj_wrap_atan2(double x, double y) { return atan2(x, y); }
LJ_FUNCA double lj_wrap_pow(double x, double y) { return pow(x, y); }
LJ_FUNCA double lj_wrap_fmod(double x, double y) { return fmod(x, y); }
#endif

/* -- Helper functions ---------------------------------------------------- */

/* Required to prevent the C compiler from applying FMA optimizations.
**
** Yes, there's -ffp-contract and the FP_CONTRACT pragma ... in theory.
** But the current state of C compilers is a mess in this regard.
** Also, this function is not performance sensitive at all.
*/
LJ_NOINLINE static double lj_vm_floormul(double x, double y)
{
  return lj_vm_floor(x / y) * y;
}

double lj_vm_foldarith(double x, double y, int op)
{
  switch (op) {
  case IR_ADD - IR_ADD: return x+y; break;
  case IR_SUB - IR_ADD: return x-y; break;
  case IR_MUL - IR_ADD: return x*y; break;
  case IR_DIV - IR_ADD: return x/y; break;
  case IR_MOD - IR_ADD: return x-lj_vm_floormul(x, y); break;
  case IR_POW - IR_ADD: return pow(x, y); break;
  case IR_NEG - IR_ADD: return -x; break;
  case IR_ABS - IR_ADD: return fabs(x); break;
#if LJ_HASJIT
  case IR_LDEXP - IR_ADD: return ldexp(x, lj_num2int(y)); break;
  case IR_MIN - IR_ADD: return x < y ? x : y; break;
  case IR_MAX - IR_ADD: return x > y ? x : y; break;
#endif
  default: return x;
  }
}

/* -- Helper functions for generated machine code ------------------------- */

/* Lua 5.4 float modulo (luai_nummod): fmod, then adjust to the divisor's
** sign. Exact for any magnitude (the floor formula b - floor(b/c)*c loses
** precision for large quotients and gives +0.0 where 5.4 keeps -0.0). The
** JIT calls this for every float '%' (lj_opt_narrow_mod, rec_i64_arith).
*/
double lj_vm_modnum(double a, double b)
{
  double m = fmod(a, b);
  if ((m > 0 && b < 0) || (m < 0 && b > 0)) m += b;  /* Sign of the divisor. */
  return m;
}

#if (LJ_HASJIT && !(LJ_TARGET_ARM || LJ_TARGET_ARM64 || LJ_TARGET_PPC)) || LJ_TARGET_MIPS
int32_t LJ_FASTCALL lj_vm_modi(int32_t a, int32_t b)
{
  int32_t r;
  /* This must be checked before using this function. */
  lj_assertX(b != 0, "modulo with zero divisor");
  /* Lua 5.4: integer modulo is a floor modulo -- the result takes the sign of
  ** the divisor (C's % takes the sign of the dividend). INT_MIN % -1 is 0
  ** (C's % traps on x86 for it: SIGFPE in traces). */
  if (b == -1) return 0;
  r = a % b;
  if (r != 0 && ((r < 0) != (b < 0)))
    r += b;
  return r;
}
#endif

#if LJ_HASJIT

#ifdef LUAJIT_NO_LOG2
double lj_vm_log2(double a)
{
  return log(a) * 1.4426950408889634074;
}
#endif

/* Computes fpm(x) for extended math functions. */
double lj_vm_foldfpm(double x, int fpm)
{
  switch (fpm) {
  case IRFPM_FLOOR: return lj_vm_floor(x);
  case IRFPM_CEIL: return lj_vm_ceil(x);
  case IRFPM_TRUNC: return lj_vm_trunc(x);
  case IRFPM_SQRT: return sqrt(x);
  case IRFPM_LOG: return log(x);
  case IRFPM_LOG2: return lj_vm_log2(x);
  default: lj_assertX(0, "bad fpm %d", fpm);
  }
  return 0;
}

#if LJ_HASFFI
int lj_vm_errno(void)
{
  return errno;
}
#endif

#endif
