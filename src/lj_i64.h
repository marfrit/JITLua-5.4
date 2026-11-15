/*
** Boxed interned 64-bit integers (ADR-001b, LuaJIT-5.4 port).
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_I64_H
#define _LJ_I64_H

#include "lj_obj.h"

/* Intern a 64-bit integer and return the (shared) object. Equal values always
** return the same pointer, so pointer equality == value equality. */
LJ_FUNC GCudata *lj_i64_box(lua_State *L, int64_t v);

/* Push a boxed integer onto the stack (ADR-001b step 1: C-side only). */
LJ_FUNC void lj_i64_push(lua_State *L, int64_t v);

/* True if the object is a boxed integer (private udtype marker). */
LJ_FUNC int LJ_FASTCALL lj_i64_isnum(cTValue *o);

#endif
