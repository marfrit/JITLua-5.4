/*
** String scanning.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_STRSCAN_H
#define _LJ_STRSCAN_H

#include "lj_obj.h"

/* Options for accepted/returned formats. */
#define STRSCAN_OPT_TOINT	0x01  /* Convert to int32_t, if possible. */
#define STRSCAN_OPT_TONUM	0x02  /* Always convert to double. */
#define STRSCAN_OPT_IMAG	0x04
#define STRSCAN_OPT_LL		0x08
#define STRSCAN_OPT_C		0x10
#define STRSCAN_OPT_TOI64	0x20  /* 5.4: integer syntax outside int32 -> STRSCAN_I64 (o->u64). */

/* Returned format. */
typedef enum {
  STRSCAN_ERROR,
  STRSCAN_NUM, STRSCAN_IMAG,
  STRSCAN_INT, STRSCAN_U32, STRSCAN_I64, STRSCAN_U64,
} StrScanFmt;

LJ_FUNC StrScanFmt lj_strscan_scan(const uint8_t *p, MSize len, TValue *o,
				   uint32_t opt);
LJ_FUNC int LJ_FASTCALL lj_strscan_num(GCstr *str, TValue *o);
/* 5.4 string->number: integer syntax yields the integer in its canonical
** encoding (int32, widened, box -- hence L), float syntax a float. */
LJ_FUNC int lj_strscan_number64(lua_State *L, GCstr *str, TValue *o);
#if LJ_DUALNUM
LJ_FUNC int LJ_FASTCALL lj_strscan_number(GCstr *str, TValue *o);
#else
#define lj_strscan_number(s, o)		lj_strscan_num((s), (o))
#endif

/* Check for number or convert string to number/int in-place (!). */
static LJ_AINLINE int lj_strscan_numberobj(TValue *o)
{
  return tvisnumber(o) || (tvisstr(o) && lj_strscan_number(strV(o), o));
}

/* Same, 5.4 integers included: a boxed integer is a number, and a string
** with integer syntax outside int32 becomes a 5.4 integer, not a float. */
#define lj_strscan_numberobj64(L, o) \
  (tvisnumber(o) || tvisi64(o) || \
   (tvisstr(o) && lj_strscan_number64((L), strV(o), (o))))

#endif
