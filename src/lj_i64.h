/*
** Boxed interned 64-bit integers (ADR-001b, LuaJIT-5.4 port).
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_I64_H
#define _LJ_I64_H

#include "lj_obj.h"

/* Operations handled by the C semantics helper (ADR-001b steps 2-3). */
typedef enum I64Op {
  I64_ADD, I64_SUB, I64_MUL, I64_DIV, I64_MOD, I64_POW, I64_UNM,
  I64_IDIV, I64_BAND, I64_BOR, I64_BXOR, I64_SHL, I64_SHR, I64_BNOT,
  I64__MAX
} I64Op;

/* Intern a 64-bit integer and return the (shared) object. Equal values always
** return the same pointer, so pointer equality == value equality. */
LJ_FUNC GCudata *lj_i64_box(lua_State *L, int64_t v);

/* Push a boxed integer onto the stack. */
LJ_FUNC void lj_i64_push(lua_State *L, int64_t v);

/* True if the object is a boxed integer (private udtype marker). */
LJ_FUNC int LJ_FASTCALL lj_i64_isnum(cTValue *o);

/* Extract the integer value of an int32 integer or a boxed integer.
** Returns 0 if the object is neither. */
LJ_FUNC int LJ_FASTCALL lj_i64_getint(cTValue *o, int64_t *p);

/* 5.4 arithmetic for operands where an int32/int64 integer is involved.
** Returns 1 if the result was stored in *ra, 0 if the caller must use the
** generic path (string coercion, metamethods, errors). */
LJ_FUNC int LJ_FASTCALL lj_i64_arith(lua_State *L, TValue *ra,
				     cTValue *rb, cTValue *rc, I64Op op);
/* Unary variant (unary minus, bnot). */
LJ_FUNC int LJ_FASTCALL lj_i64_unop(lua_State *L, TValue *ra, cTValue *rb,
				    I64Op op);

/* Map an arithmetic metamethod to the C semantics helper operation. */
LJ_FUNC I64Op lj_i64_op_from_mm(MMS mm);

/* Compare two values with 5.4 numeric rules when an int64 is involved.
** op: 0 == eq, 1 <, 2 <=. Returns 1 if handled and the result is in *res. */
LJ_FUNC int LJ_FASTCALL lj_i64_compare(cTValue *a, cTValue *b, int op,
				       int *res);

#endif
