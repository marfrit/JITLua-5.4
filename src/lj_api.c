/*
** Public Lua/C API.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lj_api_c
#define LUA_CORE

#include <stdio.h>
#include <string.h>

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_i64.h"
#include "lj_debug.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_func.h"
#include "lj_udata.h"
#include "lj_state.h"
#include "lj_bc.h"
#include "lj_meta.h"
#include "lj_frame.h"
#include "lj_trace.h"
#include "lj_vm.h"
#include "lj_strscan.h"
#include "lj_strfmt.h"

/* -- Common helper functions --------------------------------------------- */

#define lj_checkapi_slot(idx) \
  lj_checkapi((idx) <= (L->top - L->base), "stack slot %d out of range", (idx))

static TValue *index2adr(lua_State *L, int idx)
{
  if (idx > 0) {
    TValue *o = L->base + (idx - 1);
    return o < L->top ? o : niltv(L);
  } else if (idx > LUA_REGISTRYINDEX) {
    lj_checkapi(idx != 0 && -idx <= L->top - L->base,
		"bad stack slot %d", idx);
    return L->top + idx;
  } else if (idx == LUA_GLOBALSINDEX) {
    TValue *o = &G(L)->tmptv;
    settabV(L, o, tabref(L->env));
    return o;
  } else if (idx == LUA_REGISTRYINDEX) {
    return registry(L);
  } else {
    GCfunc *fn = curr_func(L);
    lj_checkapi(fn->c.gct == ~LJ_TFUNC && !isluafunc(fn),
		"calling frame is not a C function");
    if (idx == LUA_ENVIRONINDEX) {
      TValue *o = &G(L)->tmptv;
      settabV(L, o, tabref(fn->c.env));
      return o;
    } else {
      idx = LUA_GLOBALSINDEX - idx;
      return idx <= fn->c.nupvalues ? &fn->c.upvalue[idx-1] : niltv(L);
    }
  }
}

static LJ_AINLINE TValue *index2adr_check(lua_State *L, int idx)
{
  TValue *o = index2adr(L, idx);
  lj_checkapi(o != niltv(L), "invalid stack slot %d", idx);
  return o;
}

static TValue *index2adr_stack(lua_State *L, int idx)
{
  if (idx > 0) {
    TValue *o = L->base + (idx - 1);
    if (o < L->top) {
      return o;
    } else {
      lj_checkapi(0, "invalid stack slot %d", idx);
      return niltv(L);
    }
    return o < L->top ? o : niltv(L);
  } else {
    lj_checkapi(idx != 0 && -idx <= L->top - L->base,
		"invalid stack slot %d", idx);
    return L->top + idx;
  }
}

static GCtab *getcurrenv(lua_State *L)
{
  GCfunc *fn = curr_func(L);
  return fn->c.gct == ~LJ_TFUNC ? tabref(fn->c.env) : tabref(L->env);
}

/* -- Miscellaneous API functions ----------------------------------------- */

LUA_API int lua_status(lua_State *L)
{
  return L->status;
}

LUA_API int lua_checkstack(lua_State *L, int size)
{
  if (size > LUAI_MAXCSTACK || (L->top - L->base + size) > LUAI_MAXCSTACK) {
    return 0;  /* Stack overflow. */
  } else if (size > 0) {
    int avail = (int)(mref(L->maxstack, TValue) - L->top);
    if (size > avail &&
	lj_state_cpgrowstack(L, (MSize)(size - avail)) != LUA_OK) {
      L->top--;
      return 0;  /* Out of memory. */
    }
  }
  return 1;
}

LUALIB_API void luaL_checkstack(lua_State *L, int size, const char *msg)
{
  if (!lua_checkstack(L, size))
    lj_err_callerv(L, LJ_ERR_STKOVM, msg);
}

LUA_API void lua_xmove(lua_State *L, lua_State *to, int n)
{
  TValue *f, *t;
  if (L == to) return;
  lj_checkapi_slot(n);
  lj_checkapi(G(L) == G(to), "move across global states");
  lj_state_checkstack(to, (MSize)n);
  f = L->top;
  t = to->top = to->top + n;
  while (--n >= 0) copyTV(to, --t, --f);
  L->top = f;
}

/* -- Stack manipulation -------------------------------------------------- */

LUA_API int lua_gettop(lua_State *L)
{
  return (int)(L->top - L->base);
}

LUA_API void lua_settop(lua_State *L, int idx)
{
  TValue *newtop;
  ptrdiff_t nofs;
  if (idx >= 0) {
    lj_checkapi(idx <= tvref(L->maxstack) - L->base, "bad stack slot %d", idx);
    newtop = L->base + idx;
    if (newtop > L->top) {
      if (newtop >= tvref(L->maxstack)) {
	lj_state_growstack(L, (MSize)idx - (MSize)(L->top - L->base));
	newtop = L->base + idx;  /* stack may have moved */
      }
      do { setnilV(L->top++); } while (L->top < newtop);
    }
  } else {
    lj_checkapi(-(idx+1) <= (L->top - L->base), "bad stack slot %d", idx);
    newtop = L->top + idx+1;
  }
  nofs = savestack(L, newtop);
  if (newtop < L->top && L->tbcn > 0 &&
      restorestack(L, mref(L->tbclist, int32_t)[L->tbcn-1]) >= newtop) {
    TValue *eslot = L->top++;
    int st;
    setnilV(eslot);
    st = lj_meta_tbccloseall(L, newtop, eslot);
    if (st != LUA_OK) {
      L->top = eslot+1;
      lj_err_throw(L, st);
    }
    L->top = eslot;
  }
  L->top = restorestack(L, nofs);
}

LUA_API void lua_remove(lua_State *L, int idx)
{
  TValue *p = index2adr_stack(L, idx);
  while (++p < L->top) copyTV(L, p-1, p);
  L->top--;
}

LUA_API void lua_insert(lua_State *L, int idx)
{
  TValue *q, *p = index2adr_stack(L, idx);
  for (q = L->top; q > p; q--) copyTV(L, q, q-1);
  copyTV(L, p, L->top);
}

/* Lua 5.4: rotate the range [idx, top] by n positions toward the top. */
LUA_API void lua_rotate(lua_State *L, int idx, int n)
{
  TValue *p = index2adr_stack(L, idx);
  TValue *t = L->top - 1;
  ptrdiff_t count = t - p + 1;
  ptrdiff_t k, i;
  if (count <= 1) return;
  if (n < 0) n += (int)count;
  lj_checkapi(n >= 0 && n < (int)count, "invalid rotation %d", n);
  k = count - n;  /* rotate toward the top == left-rotate by count-n */
  for (i = 0; i < k/2; i++) {
    TValue tmp;
    copyTV(L, &tmp, p+i); copyTV(L, p+i, p+k-1-i); copyTV(L, p+k-1-i, &tmp);
  }
  for (i = 0; i < (count-k)/2; i++) {
    TValue tmp;
    copyTV(L, &tmp, p+k+i); copyTV(L, p+k+i, t-i); copyTV(L, t-i, &tmp);
  }
  for (i = 0; i < count/2; i++) {
    TValue tmp;
    copyTV(L, &tmp, p+i); copyTV(L, p+i, t-i); copyTV(L, t-i, &tmp);
  }
}

static void copy_slot(lua_State *L, TValue *f, int idx)
{
  if (idx == LUA_GLOBALSINDEX) {
    lj_checkapi(tvistab(f), "stack slot %d is not a table", idx);
    /* NOBARRIER: A thread (i.e. L) is never black. */
    setgcref(L->env, obj2gco(tabV(f)));
  } else if (idx == LUA_ENVIRONINDEX) {
    GCfunc *fn = curr_func(L);
    if (fn->c.gct != ~LJ_TFUNC)
      lj_err_msg(L, LJ_ERR_NOENV);
    lj_checkapi(tvistab(f), "stack slot %d is not a table", idx);
    setgcref(fn->c.env, obj2gco(tabV(f)));
    lj_gc_barrier(L, fn, f);
  } else {
    TValue *o = index2adr_check(L, idx);
    copyTV(L, o, f);
    if (idx < LUA_GLOBALSINDEX)  /* Need a barrier for upvalues. */
      lj_gc_barrier(L, curr_func(L), f);
  }
}

LUA_API void lua_replace(lua_State *L, int idx)
{
  lj_checkapi_slot(1);
  copy_slot(L, L->top - 1, idx);
  L->top--;
}

LUA_API void lua_toclose(lua_State *L, int idx)
{
  TValue *o = index2adr_stack(L, idx);
  int32_t *list = mref(L->tbclist, int32_t);
  lj_checkapi(L->tbcn == 0 || restorestack(L, list[L->tbcn-1]) < o,
	      "given index below or equal a marked one");
  UNUSED(list);
  lj_meta_tbcmark(L, o);
}

LUA_API void lua_closeslot(lua_State *L, int idx)
{
  TValue *o = index2adr_stack(L, idx);
  int32_t *list = mref(L->tbclist, int32_t);
  ptrdiff_t oofs = savestack(L, o);
  TValue *eslot;
  int st;
  lj_checkapi(L->tbcn > 0 && list[L->tbcn-1] == (int32_t)oofs,
	      "no variable to close at given level");
  UNUSED(list);
  eslot = L->top++;
  setnilV(eslot);
  st = lj_meta_tbccloseall(L, o, eslot);
  if (st != LUA_OK) {
    L->top = eslot+1;  /* error object for the throw */
    lj_err_throw(L, st);
  }
  L->top = eslot;
  o = restorestack(L, oofs);
  setnilV(o);
}

LUA_API void lua_copy(lua_State *L, int fromidx, int toidx)
{
  copy_slot(L, index2adr(L, fromidx), toidx);
}

LUA_API void lua_pushvalue(lua_State *L, int idx)
{
  copyTV(L, L->top, index2adr(L, idx));
  incr_top(L);
}

/* -- Stack getters ------------------------------------------------------- */

LUA_API int lua_type(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  if (tvisnumber(o) || tvisi64(o)) {  /* ADR-001b: boxed int64 is a number */
    return LUA_TNUMBER;
#if LJ_64 && !LJ_GC64
  } else if (tvislightud(o)) {
    return LUA_TLIGHTUSERDATA;
#endif
  } else if (o == niltv(L)) {
    return LUA_TNONE;
  } else {  /* Magic internal/external tag conversion. ORDER LJ_T */
    uint32_t t = ~itype(o);
#if LJ_64
    int tt = (int)((U64x(75a06,98042110) >> 4*t) & 15u);
#else
    int tt = (int)(((t < 8 ? 0x98042110u : 0x75a06u) >> 4*(t&7)) & 15u);
#endif
    lj_assertL(tt != LUA_TNIL || tvisnil(o), "bad tag conversion");
    return tt;
  }
}

LUALIB_API void luaL_checktype(lua_State *L, int idx, int tt)
{
  if (lua_type(L, idx) != tt)
    lj_err_argt(L, idx, tt);
}

LUALIB_API void luaL_checkany(lua_State *L, int idx)
{
  if (index2adr(L, idx) == niltv(L))
    lj_err_arg(L, idx, LJ_ERR_NOVAL);
}

LUA_API const char *lua_typename(lua_State *L, int t)
{
  UNUSED(L);
  return lj_obj_typename[t+1];
}

LUA_API int lua_iscfunction(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  return tvisfunc(o) && !isluafunc(funcV(o));
}

LUA_API int lua_isnumber(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  TValue tmp;
  /* ADR-001b: a boxed int64 is a number too. */
  return (tvisnumber(o) || tvisi64(o) ||
	  (tvisstr(o) && lj_strscan_number(strV(o), &tmp)));
}

LUA_API int lua_isstring(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  return (tvisstr(o) || tvisnumber(o));
}

LUA_API int lua_isuserdata(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  return (tvisudata(o) || tvislightud(o));
}

LUA_API int lua_rawequal(lua_State *L, int idx1, int idx2)
{
  cTValue *o1 = index2adr(L, idx1);
  cTValue *o2 = index2adr(L, idx2);
  return (o1 == niltv(L) || o2 == niltv(L)) ? 0 : lj_obj_equal(o1, o2);
}

LUA_API int lua_equal(lua_State *L, int idx1, int idx2)
{
  cTValue *o1 = index2adr(L, idx1);
  cTValue *o2 = index2adr(L, idx2);
  if (tvisint(o1) && !tvisi47w(o1) && tvisint(o2) && !tvisi47w(o2)) {
    return intV(o1) == intV(o2);
  } else if (tvisnumber(o1) && tvisnumber(o2)) {
    return numberVnum(o1) == numberVnum(o2);
  } else if (itype(o1) != itype(o2)) {
    return 0;
  } else if (tvispri(o1)) {
    return o1 != niltv(L) && o2 != niltv(L);
#if LJ_64 && !LJ_GC64
  } else if (tvislightud(o1)) {
    return o1->u64 == o2->u64;
#endif
  } else if (gcrefeq(o1->gcr, o2->gcr)) {
    return 1;
  } else if (!tvistabud(o1)) {
    return 0;
  } else {
    TValue *base = lj_meta_equal(L, gcV(o1), gcV(o2), 0);
    if ((uintptr_t)base <= 1) {
      return (int)(uintptr_t)base;
    } else {
      L->top = base+2;
      lj_vm_call(L, base, 1+1);
      L->top -= 2+LJ_FR2;
      return tvistruecond(L->top+1+LJ_FR2);
    }
  }
}

LUA_API int lua_lessthan(lua_State *L, int idx1, int idx2)
{
  cTValue *o1 = index2adr(L, idx1);
  cTValue *o2 = index2adr(L, idx2);
  int64_t a, b;
  if (o1 == niltv(L) || o2 == niltv(L)) {
    return 0;
  } else if (tvisint(o1) && tvisint(o2)) {
    /* Inline integers: table.sort's default comparator lands here, so the
    ** int32 case stays the one compare it was; a widened 47-bit operand
    ** (payload bits 32..46 set) takes the exact 64-bit path. */
    if (LJ_LIKELY(((o1->it | o2->it) & 0x7fffu) == 0))
      return intV(o1) < intV(o2);
    a = tvisi47w(o1) ? intV47(o1) : (int64_t)intV(o1);
    b = tvisi47w(o2) ? intV47(o2) : (int64_t)intV(o2);
    return a < b;
  } else if (tvisnumber(o1) && tvisnumber(o2)) {
    return numberVnum(o1) < numberVnum(o2);
  } else if (lj_i64_getint(o1, &a) && lj_i64_getint(o2, &b)) {
    return a < b;  /* A boxed integer on at least one side. */
  } else {
    TValue *base = lj_meta_comp(L, o1, o2, 0);
    if ((uintptr_t)base <= 1) {
      return (int)(uintptr_t)base;
    } else {
      L->top = base+2;
      lj_vm_call(L, base, 1+1);
      L->top -= 2+LJ_FR2;
      return tvistruecond(L->top+1+LJ_FR2);
    }
  }
}

/* -- Lua 5.4 API additions (MISSION P1.6) -------------------------------- */

LUA_API int lua_absindex(lua_State *L, int idx)
{
  return (idx > 0 || idx <= LUA_REGISTRYINDEX) ? idx : lua_gettop(L) + idx + 1;
}

LUA_API int lua_isinteger(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  return tvisint(o) || tvisi47w(o) || tvisi64(o);  /* inline/widened/boxed int */
}

/* Push an exact 5.4 integer key (int32, widened 47-bit, or boxed int64).
** setint64V would turn a large key into a float, which cannot index a table
** with the exact integer key. */
static void api_pushkey(lua_State *L, lua_Integer n)
{
  if (LJ_DUALNUM && n == (int64_t)(int32_t)n) {
    setintV(L->top, (int32_t)n);
#if LJ_GC64
  } else if (i47_fits((int64_t)n)) {
    setint47V(L->top, (int64_t)n);
#endif
  } else {
    /* Box allocation may move the stack: take L->top only after it. */
    GCudata *ud = lj_i64_box(L, (int64_t)n);
    setudataV(L, L->top, ud);
  }
  incr_top(L);
}

LUA_API int lua_geti(lua_State *L, int idx, lua_Integer n)
{
  cTValue *v, *t = index2adr_check(L, idx);
  TValue key;
  if ((LJ_DUALNUM && n == (int64_t)(int32_t)n)
#if LJ_GC64
      || i47_fits((int64_t)n)
#endif
      ) {
    /* Inline key: fast path, no stack rearrangement. */
    if (LJ_DUALNUM && n == (int64_t)(int32_t)n)
      setintV(&key, (int32_t)n);
#if LJ_GC64
    else
      setint47V(&key, (int64_t)n);
#endif
    v = lj_meta_tget(L, t, &key);
    if (v == NULL) {
      L->top += 2;
      lj_vm_call(L, L->top-2, 1+1);
      L->top -= 2+LJ_FR2;
      v = L->top+1+LJ_FR2;
    }
    copyTV(L, L->top, v);
    incr_top(L);
    return lua_type(L, -1);
  }
  /* Boxed int64 key: exactly 5.4. Root it on the stack while tget may run a
  ** metamethod. */
  copyTV(L, L->top, t);  /* table copy, so idx stays valid */
  incr_top(L);
  api_pushkey(L, n);
  lua_gettable(L, -2);  /* pops the key, pushes the value */
  lua_remove(L, -2);  /* drop the table copy, keep the result */
  return lua_type(L, -1);
}

LUA_API void lua_seti(lua_State *L, int idx, lua_Integer n)
{
  TValue *o;
  TValue key;
  cTValue *t = index2adr_check(L, idx);
  lj_checkapi_slot(1);
  if ((LJ_DUALNUM && n == (int64_t)(int32_t)n)
#if LJ_GC64
      || i47_fits((int64_t)n)
#endif
      ) {
    /* Inline key: the stock path. */
    if (LJ_DUALNUM && n == (int64_t)(int32_t)n)
      setintV(&key, (int32_t)n);
#if LJ_GC64
    else
      setint47V(&key, (int64_t)n);
#endif
    o = lj_meta_tset(L, t, &key);
    if (o) {
      /* NOBARRIER: lj_meta_tset ensures the table is not black. */
      copyTV(L, o, --L->top);
    } else {
      TValue *base = L->top;
      copyTV(L, base+2, base-3-2*LJ_FR2);
      L->top = base+3;
      lj_vm_call(L, base, 0+1);
      L->top -= 2+LJ_FR2;
    }
    return;
  }
  {
    lj_checkapi_slot(2);
    copyTV(L, L->top, t);
    incr_top(L);
    api_pushkey(L, n);
    copyTV(L, L->top, L->top - 3);  /* copy of the value for lua_settable */
    incr_top(L);
    lua_settable(L, -3);
    L->top -= 2;  /* drop the pushed table copy and the consumed value */
  }
}

LUA_API void lua_len(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  if (tvisstr(o)) {
    setint64V(L->top, (int64_t)strV(o)->len);
    incr_top(L);
  } else if (tvistab(o) || tvisudata(o)) {
    cTValue *mo = lj_meta_lookup(L, o, MM_len);
    if (!tvisnil(mo)) {
      TValue *base = L->top;
      copyTV(L, base, mo);
      copyTV(L, base+1, o);
      L->top = base+2;
      lua_call(L, 1, 1);
    } else {
      if (tvistab(o))
	setint64V(L->top, (int64_t)lj_tab_len(tabV(o)));
      else
	setint64V(L->top, (int64_t)udataV(o)->len);
      incr_top(L);
    }
  } else {
    lj_err_optype(L, o, LJ_ERR_OPLEN);
  }
}

LUA_API int lua_compare(lua_State *L, int idx1, int idx2, int op)
{
  cTValue *o1 = index2adr(L, idx1);
  cTValue *o2 = index2adr(L, idx2);
  if (op == LUA_OPEQ)
    return lua_equal(L, idx1, idx2);
  if (o1 == niltv(L) || o2 == niltv(L))
    return 0;
  if (tvisint(o1) && !tvisi47w(o1) && tvisint(o2) && !tvisi47w(o2))
    return (op == LUA_OPLT) ? (intV(o1) < intV(o2)) : (intV(o1) <= intV(o2));
  if (tvisnumber(o1) && tvisnumber(o2)) {
    lua_Number a = numberVnum(o1), b = numberVnum(o2);
    return (op == LUA_OPLT) ? (a < b) : (a <= b);
  }
  {
    /* lj_meta_comp: bit 0 inverts the result, bit 1 selects __le. */
    TValue *base = lj_meta_comp(L, o1, o2, (op == LUA_OPLE) ? 2 : 0);
    if ((uintptr_t)base <= 1)
      return (int)(uintptr_t)base;
    L->top = base+2;
    lj_vm_call(L, base, 1+1);
    L->top -= 2+LJ_FR2;
    return tvistruecond(L->top+1+LJ_FR2);
  }
}

LUA_API void lua_arith(lua_State *L, int op)
{
  TValue *ra, *rb, *rc, *base;
  ptrdiff_t raofs;
  BCOp bop;
  int bit;
  lj_checkapi(op >= LUA_OPADD && op <= LUA_OPBNOT, "invalid option");
  if (op != LUA_OPUNM && op != LUA_OPBNOT) {
    lj_checkapi_slot(2);
    ra = L->top-2;
  } else {  /* unary: duplicate the operand like PUC's fake second operand */
    lj_checkapi_slot(1);
    copyTV(L, L->top, L->top-1);
    incr_top(L);
    ra = L->top-2;
  }
  rb = ra; rc = L->top-1;
  raofs = savestack(L, ra);
  switch (op) {
  case LUA_OPADD: bop = BC_ADDVV; bit = 0; break;
  case LUA_OPSUB: bop = BC_SUBVV; bit = 0; break;
  case LUA_OPMUL: bop = BC_MULVV; bit = 0; break;
  case LUA_OPMOD: bop = BC_MODVV; bit = 0; break;
  case LUA_OPPOW: bop = BC_POW; bit = 0; break;
  case LUA_OPDIV: bop = BC_DIVVV; bit = 0; break;
  case LUA_OPIDIV: bop = BC_IDIV; bit = 0; break;
  case LUA_OPBAND: bop = BC_BAND; bit = 1; break;
  case LUA_OPBOR: bop = BC_BOR; bit = 1; break;
  case LUA_OPBXOR: bop = BC_BXOR; bit = 1; break;
  case LUA_OPSHL: bop = BC_BSHL; bit = 1; break;
  case LUA_OPSHR: bop = BC_BSHR; bit = 1; break;
  case LUA_OPUNM: bop = BC_UNM; bit = 0; break;
  case LUA_OPBNOT: bop = BC_BNOT; bit = 1; break;
  default: lj_checkapi(0, "invalid option"); return;
  }
  base = bit ? lj_meta_bitop(L, rb, rb, rc, bop)
             : lj_meta_arith(L, rb, rb, rc, bop);
  if ((uintptr_t)base <= 1) {  /* finished; result is in the first slot */
    ra = restorestack(L, raofs);
    L->top = ra+1;
  } else {  /* metamethod call, like lua_compare */
    L->top = base+2;
    lj_vm_call(L, base, 1+1);
    L->top -= 2+LJ_FR2;
    ra = restorestack(L, raofs);
    copyTV(L, ra, L->top+1+LJ_FR2);
    L->top = ra+1;
  }
}

LUA_API size_t lua_stringtonumber(lua_State *L, const char *s)
{
  TValue o;
  size_t len = strlen(s);
  const char *p = s;
  StrScanFmt fmt;
  /* 5.4 does not accept "inf"/"nan" here (unlike tonumber). */
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' ||
	 *p == '\v' || *p == '\f') p++;
  if (*p == '+' || *p == '-') p++;
  if ((p[0]|0x20) == 'i' || (p[0]|0x20) == 'n')
    return 0;
#if LJ_DUALNUM
  fmt = lj_strscan_scan((const uint8_t *)s, (MSize)len, &o, STRSCAN_OPT_TOINT);
  if (fmt == STRSCAN_ERROR) return 0;
  if (fmt == STRSCAN_INT) setitype(&o, LJ_TISNUM);
#else
  fmt = lj_strscan_scan((const uint8_t *)s, (MSize)len, &o, STRSCAN_OPT_TONUM);
  if (fmt == STRSCAN_ERROR) return 0;
#endif
  copyTV(L, L->top, &o);
  incr_top(L);
  return len+1;
}

LUA_API lua_Number lua_tonumber(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  TValue tmp;
  if (LJ_LIKELY(tvisnumber(o)))
    return numberVnum(o);
  else if (tvisi64(o))
    return (lua_Number)i64V(o);
  else if (tvisstr(o) && lj_strscan_num(strV(o), &tmp))
    return numV(&tmp);
  else
    return 0;
}

LUA_API lua_Number lua_tonumberx(lua_State *L, int idx, int *ok)
{
  cTValue *o = index2adr(L, idx);
  TValue tmp;
  if (LJ_LIKELY(tvisnumber(o))) {
    if (ok) *ok = 1;
    return numberVnum(o);
  } else if (tvisi64(o)) {
    if (ok) *ok = 1;
    return (lua_Number)i64V(o);
  } else if (tvisi47w(o)) {  /* widened inline int as a double */
    if (ok) *ok = 1;
    return (lua_Number)intV47(o);
  } else if (tvisi64(o)) {  /* ADR-001b: boxed int64 as a double */
    if (ok) *ok = 1;
    return (lua_Number)i64V(o);
  } else if (tvisstr(o) && lj_strscan_num(strV(o), &tmp)) {
    if (ok) *ok = 1;
    return numV(&tmp);
  } else {
    if (ok) *ok = 0;
    return 0;
  }
}

LUALIB_API lua_Number luaL_checknumber(lua_State *L, int idx)
{
  int ok;
  lua_Number n = lua_tonumberx(L, idx, &ok);
  if (!ok) lj_err_argt(L, idx, LUA_TNUMBER);
  return n;
}

LUALIB_API lua_Number luaL_optnumber(lua_State *L, int idx, lua_Number def)
{
  cTValue *o = index2adr(L, idx);
  TValue tmp;
  if (LJ_LIKELY(tvisnumber(o)))
    return numberVnum(o);
  else if (tvisnil(o))
    return def;
  else if (!(tvisstr(o) && lj_strscan_num(strV(o), &tmp)))
    lj_err_argt(L, idx, LUA_TNUMBER);
  return numV(&tmp);
}

LUA_API lua_Integer lua_tointeger(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  TValue tmp;
  lua_Number n;
  if (LJ_LIKELY(tvisint(o))) {
    return tvisi47w(o) ? (lua_Integer)intV47(o) : intV(o);
  } else if (tvisi64(o)) {  /* boxed int64 must not read the udata word */
    return (lua_Integer)i64V(o);
  } else if (LJ_LIKELY(tvisnum(o))) {
    n = numV(o);
  } else {
    if (!(tvisstr(o) && lj_strscan_number64(L, strV(o), &tmp)))
      return 0;
    if (tvisi64(&tmp))
      return (lua_Integer)i64V(&tmp);
    if (tvisint(&tmp))
      return tvisi47w(&tmp) ? (lua_Integer)intV47(&tmp) : intV(&tmp);
    n = numV(&tmp);
  }
  {
    int64_t i64;
    return lj_i64_numtoint(n, &i64) ? (lua_Integer)i64 : 0;
  }
}

LUA_API lua_Integer lua_tointegerx(lua_State *L, int idx, int *ok)
{
  cTValue *o = index2adr(L, idx);
  TValue tmp;
  lua_Number n;
  if (LJ_LIKELY(tvisint(o) && !tvisi47w(o))) {  /* int32 inline only */
    if (ok) *ok = 1;
    return intV(o);
#if LJ_GC64
  } else if (tvisi47w(o)) {  /* ADR-001b step 6: widened 47-bit inline */
    if (ok) *ok = 1;
    return (lua_Integer)intV47(o);
#endif
  } else if (tvisi64(o)) {  /* ADR-001b: exact 64-bit integer */
    if (ok) *ok = 1;
    return (lua_Integer)i64V(o);
  } else if (LJ_LIKELY(tvisnum(o))) {
    n = numV(o);
  } else {
    if (!(tvisstr(o) && lj_strscan_number64(L, strV(o), &tmp))) {
      if (ok) *ok = 0;
      return 0;
    }
    if (tvisi64(&tmp)) {  /* 5.4: numeric strings keep exact int64 */
      if (ok) *ok = 1;
      return (lua_Integer)i64V(&tmp);
    }
    if (tvisint(&tmp)) {
      if (ok) *ok = 1;
      return tvisi47w(&tmp) ? (lua_Integer)intV47(&tmp) : intV(&tmp);
    }
    n = numV(&tmp);
  }
  {
    int64_t i64;
    if (!lj_i64_numtoint(n, &i64)) {  /* non-integral/NaN/inf/out of range */
      if (ok) *ok = 0;
      return 0;
    }
    if (ok) *ok = 1;
    return (lua_Integer)i64;
  }
}

LUALIB_API lua_Integer luaL_checkinteger(lua_State *L, int idx)
{
  int ok;
  lua_Integer n = lua_tointegerx(L, idx, &ok);
  if (!ok) lj_err_argt(L, idx, LUA_TNUMBER);
  return n;
}

LUALIB_API lua_Integer luaL_optinteger(lua_State *L, int idx, lua_Integer def)
{
  int ok;
  lua_Integer n = lua_tointegerx(L, idx, &ok);
  if (!ok) {
    if (tvisnil(index2adr(L, idx))) return def;
    lj_err_argt(L, idx, LUA_TNUMBER);
  }
  return n;
}

LUA_API int lua_toboolean(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  return tvistruecond(o);
}

LUA_API const char *lua_tolstring(lua_State *L, int idx, size_t *len)
{
  TValue *o = index2adr(L, idx);
  GCstr *s;
  if (LJ_LIKELY(tvisstr(o))) {
    s = strV(o);
  } else if (tvisnumber(o) || tvisi64(o)) {  /* ADR-001b: box converts */
    lj_gc_check(L);
    o = index2adr(L, idx);  /* GC may move the stack. */
    s = lj_strfmt_number(L, o);
    setstrV(L, o, s);
  } else {
    if (len != NULL) *len = 0;
    return NULL;
  }
  if (len != NULL) *len = s->len;
  return strdata(s);
}

LUALIB_API const char *luaL_checklstring(lua_State *L, int idx, size_t *len)
{
  TValue *o = index2adr(L, idx);
  GCstr *s;
  if (LJ_LIKELY(tvisstr(o))) {
    s = strV(o);
  } else if (tvisnumber(o)) {
    lj_gc_check(L);
    o = index2adr(L, idx);  /* GC may move the stack. */
    s = lj_strfmt_number(L, o);
    setstrV(L, o, s);
  } else {
    lj_err_argt(L, idx, LUA_TSTRING);
  }
  if (len != NULL) *len = s->len;
  return strdata(s);
}

LUALIB_API const char *luaL_optlstring(lua_State *L, int idx,
				       const char *def, size_t *len)
{
  TValue *o = index2adr(L, idx);
  GCstr *s;
  if (LJ_LIKELY(tvisstr(o))) {
    s = strV(o);
  } else if (tvisnil(o)) {
    if (len != NULL) *len = def ? strlen(def) : 0;
    return def;
  } else if (tvisnumber(o)) {
    lj_gc_check(L);
    o = index2adr(L, idx);  /* GC may move the stack. */
    s = lj_strfmt_number(L, o);
    setstrV(L, o, s);
  } else {
    lj_err_argt(L, idx, LUA_TSTRING);
  }
  if (len != NULL) *len = s->len;
  return strdata(s);
}

LUALIB_API int luaL_checkoption(lua_State *L, int idx, const char *def,
				const char *const lst[])
{
  ptrdiff_t i;
  const char *s = lua_tolstring(L, idx, NULL);
  if (s == NULL && (s = def) == NULL)
    lj_err_argt(L, idx, LUA_TSTRING);
  for (i = 0; lst[i]; i++)
    if (strcmp(lst[i], s) == 0)
      return (int)i;
  lj_err_argv(L, idx, LJ_ERR_INVOPTM, s);
}

LUA_API void lua_pushglobaltable(lua_State *L)
{
  settabV(L, L->top, tabref(L->env));  /* 5.4 C API name */
  incr_top(L);
}

LUA_API lua_Unsigned lua_rawlen(lua_State *L, int idx)
{
  /* 5.4 name and type for the same primitive as lua_objlen. */
  return (lua_Unsigned)lua_objlen(L, idx);
}

LUA_API size_t lua_objlen(lua_State *L, int idx)
{
  TValue *o = index2adr(L, idx);
  if (tvisstr(o)) {
    return strV(o)->len;
  } else if (tvistab(o)) {
    return (size_t)lj_tab_len(tabV(o));
  } else if (tvisudata(o)) {
    return udataV(o)->len;
  } else if (tvisnumber(o)) {
    GCstr *s = lj_strfmt_number(L, o);
    setstrV(L, o, s);
    return s->len;
  } else {
    return 0;
  }
}

LUA_API lua_CFunction lua_tocfunction(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  if (tvisfunc(o)) {
    BCOp op = bc_op(*mref(funcV(o)->c.pc, BCIns));
    if (op == BC_FUNCC || op == BC_FUNCCW)
      return funcV(o)->c.f;
  }
  return NULL;
}

LUA_API void *lua_touserdata(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  if (tvisudata(o) && !tvisi64(o))  /* ADR-001b: a box is not userdata */
    return uddata(udataV(o));
  else if (tvislightud(o))
    return lightudV(G(L), o);
  else
    return NULL;
}

LUA_API lua_State *lua_tothread(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  return (!tvisthread(o)) ? NULL : threadV(o);
}

LUA_API const void *lua_topointer(lua_State *L, int idx)
{
  return lj_obj_ptr(G(L), index2adr(L, idx));
}

/* -- Stack setters (object creation) ------------------------------------- */

LUA_API void lua_pushnil(lua_State *L)
{
  setnilV(L->top);
  incr_top(L);
}

LUA_API void lua_pushnumber(lua_State *L, lua_Number n)
{
  setnumV(L->top, n);
  if (LJ_UNLIKELY(tvisnan(L->top))) {
    /* Canonicalize injected NaNs, keeping the sign: 5.4 prints "nan" and
    ** "-nan" apart (lua-cjson decodes "NaN" to a positive NaN). A positive
    ** quiet NaN never aliases a tagged value. */
    if (L->top->u64 >> 63) setnanV(L->top); else L->top->u64 = U64x(7ff80000,00000000);
  }
  incr_top(L);
}

LUA_API void lua_pushinteger(lua_State *L, lua_Integer n)
{
  lj_i64_toTValue(L, L->top, (int64_t)n);  /* exact: inline or interned box */
  incr_top(L);
}

LUA_API void lua_pushlstring(lua_State *L, const char *str, size_t len)
{
  GCstr *s;
  lj_gc_check(L);
  s = lj_str_new(L, str, len);
  setstrV(L, L->top, s);
  incr_top(L);
}

LUA_API void lua_pushstring(lua_State *L, const char *str)
{
  if (str == NULL) {
    setnilV(L->top);
  } else {
    GCstr *s;
    lj_gc_check(L);
    s = lj_str_newz(L, str);
    setstrV(L, L->top, s);
  }
  incr_top(L);
}

LUA_API const char *lua_pushvfstring(lua_State *L, const char *fmt,
				     va_list argp)
{
  lj_gc_check(L);
  return lj_strfmt_pushvf(L, fmt, argp);
}

LUA_API const char *lua_pushfstring(lua_State *L, const char *fmt, ...)
{
  const char *ret;
  va_list argp;
  lj_gc_check(L);
  va_start(argp, fmt);
  ret = lj_strfmt_pushvf(L, fmt, argp);
  va_end(argp);
  return ret;
}

LUA_API void lua_pushcclosure(lua_State *L, lua_CFunction f, int n)
{
  GCfunc *fn;
  lj_gc_check(L);
  lj_checkapi_slot(n);
  fn = lj_func_newC(L, (MSize)n, getcurrenv(L));
  fn->c.f = f;
  L->top -= n;
  while (n--)
    copyTV(L, &fn->c.upvalue[n], L->top+n);
  setfuncV(L, L->top, fn);
  lj_assertL(iswhite(obj2gco(fn)), "new GC object is not white");
  incr_top(L);
}

LUA_API void lua_pushboolean(lua_State *L, int b)
{
  setboolV(L->top, (b != 0));
  incr_top(L);
}

LUA_API void lua_pushlightuserdata(lua_State *L, void *p)
{
#if LJ_64
  p = lj_lightud_intern(L, p);
#endif
  setrawlightudV(L->top, p);
  incr_top(L);
}

LUA_API void lua_createtable(lua_State *L, int narray, int nrec)
{
  lj_gc_check(L);
  settabV(L, L->top, lj_tab_new_ah(L, (uint32_t)narray, (uint32_t)nrec));
  incr_top(L);
}

LUALIB_API int luaL_newmetatable(lua_State *L, const char *tname)
{
  GCtab *regt = tabV(registry(L));
  TValue *tv = lj_tab_setstr(L, regt, lj_str_newz(L, tname));
  if (tvisnil(tv)) {
    GCtab *mt = lj_tab_new(L, 0, 1);
    settabV(L, tv, mt);
    settabV(L, L->top++, mt);
    lj_gc_anybarriert(L, regt);
    return 1;
  } else {
    copyTV(L, L->top++, tv);
    return 0;
  }
}

LUA_API int lua_pushthread(lua_State *L)
{
  setthreadV(L, L->top, L);
  incr_top(L);
  return (mainthread(G(L)) == L);
}

LUA_API lua_State *lua_newthread(lua_State *L)
{
  lua_State *L1;
  lj_gc_check(L);
  L1 = lj_state_new(L);
  setthreadV(L, L->top, L1);
  incr_top(L);
  return L1;
}

LUA_API void *lua_newuserdatauv(lua_State *L, size_t size, int nuvalue)
{
  GCudata *ud;
  /* PUC: 0 <= nuvalue < USHRT_MAX (api_check); an error here, not UB. */
  if (nuvalue < 0 || nuvalue >= 65535)
    lj_err_callermsg(L, "lua_newuserdatauv: invalid user value count");
  lj_gc_check(L);
  if (size > LJ_MAX_UDATA)
    lj_err_msg(L, LJ_ERR_UDATAOV);
  ud = lj_udata_newuv(L, (MSize)size, (MSize)nuvalue, getcurrenv(L));
  setudataV(L, L->top, ud);
  incr_top(L);
  return uddata(ud);
}

LUA_API void *lua_newuserdata(lua_State *L, size_t size)
{
  return lua_newuserdatauv(L, size, 1);
}

LUA_API void lua_concat(lua_State *L, int n)
{
  lj_checkapi_slot(n);
  if (n >= 2) {
    n--;
    do {
      TValue *top = lj_meta_cat(L, L->top-1, -n);
      if (top == NULL) {
	L->top -= n;
	break;
      }
      n -= (int)(L->top - (top - 2*LJ_FR2));
      L->top = top+2;
      lj_vm_call(L, top, 1+1);
      L->top -= 1+LJ_FR2;
      copyTV(L, L->top-1, L->top+LJ_FR2);
    } while (--n > 0);
  } else if (n == 0) {  /* Push empty string. */
    setstrV(L, L->top, &G(L)->strempty);
    incr_top(L);
  }
  /* else n == 1: nothing to do. */
}

/* -- Warnings ------------------------------------------------------------ */

/* PUC 5.4 default warn handler state machine, stored in the registry because
** LuaJIT has no global_State warnf fields here: 0 = off, 1 = on, 2 = continuing
** a message. lua_warning never dispatches to a Lua `warn` replacement (PUC: the
** C API hook is independent of the library function). */
#define WARN_REG_STATE	"_LJ_WARN_STATE"

static int lj_api_warn_state(lua_State *L)
{
  int st = 0;
  lua_pushliteral(L, WARN_REG_STATE);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnumber(L, -1)) st = (int)lua_tointeger(L, -1);
  lua_pop(L, 1);
  return st;
}

static void lj_api_warn_setstate(lua_State *L, int st)
{
  lua_pushliteral(L, WARN_REG_STATE);
  lua_pushinteger(L, st);
  lua_rawset(L, LUA_REGISTRYINDEX);
}

/* The default 5.4 warning emitters (lauxlib warnfon/warnfcont semantics). */
LJ_FUNC void lj_api_warn_emit(lua_State *L, const char *msg, int tocont)
{
  int st = lj_api_warn_state(L);
  if (msg == NULL) msg = "";
  if (!tocont && msg[0] == '@') {  /* control message */
    if (strcmp(msg, "@off") == 0) { lj_api_warn_setstate(L, 0); return; }
    if (strcmp(msg, "@on") == 0) { lj_api_warn_setstate(L, 1); return; }
    return;  /* unknown control: ignored */
  }
  if (st == 0) return;  /* warnings off */
  if (st != 2) fputs("Lua warning: ", stderr);  /* start a new warning */
  fputs(msg, stderr);
  if (tocont) {
    lj_api_warn_setstate(L, 2);
  } else {
    fputc('\n', stderr);
    fflush(stderr);
    lj_api_warn_setstate(L, 1);
  }
}

/* PUC 5.4 lua_setwarnf: the C warning hook is independent of the Lua `warn`
** function. Stored in the registry as a small userdata {fn, ud}; NULL resets
** to the default emitter state machine. */
typedef struct lua_WarnCtx { lua_WarnFunction f; void *ud; } lua_WarnCtx;

LUA_API void lua_setwarnf(lua_State *L, lua_WarnFunction f, void *ud)
{
  if (f == NULL) {
    lua_pushliteral(L, "_LJ_WARN_HOOK");
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
  } else {
    lua_WarnCtx *c = (lua_WarnCtx *)lua_newuserdata(L, sizeof(lua_WarnCtx));
    c->f = f;
    c->ud = ud;
    lua_pushliteral(L, "_LJ_WARN_HOOK");
    lua_insert(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

LUA_API void lua_warning(lua_State *L, const char *msg, int tocont)
{
  int top = lua_gettop(L);
  lua_pushliteral(L, "_LJ_WARN_HOOK");
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isuserdata(L, -1)) {
    lua_WarnCtx *c = (lua_WarnCtx *)lua_touserdata(L, -1);
    if (c && c->f) {
      lua_settop(L, top);
      c->f(c->ud, msg ? msg : "", tocont);
      return;
    }
  }
  lua_settop(L, top);
  lj_api_warn_emit(L, msg, tocont);
}

#ifndef LUAI_MAXCCALLS
#define LUAI_MAXCCALLS 200
#endif

LUA_API int lua_setcstacklimit(lua_State *L, unsigned int limit)
{
  UNUSED(L); UNUSED(limit);
  return LUAI_MAXCCALLS;  /* LuaJIT keeps its own stack limits */
}

/* -- Object getters ------------------------------------------------------ */

LUA_API int lua_gettable(lua_State *L, int idx)
{
  cTValue *t = index2adr_check(L, idx);
  cTValue *v = lj_meta_tget(L, t, L->top-1);
  if (v == NULL) {
    L->top += 2;
    lj_vm_call(L, L->top-2, 1+1);
    L->top -= 2+LJ_FR2;
    v = L->top+1+LJ_FR2;
  }
  copyTV(L, L->top-1, v);
  return lua_type(L, -1);
}

LUA_API int lua_getglobal(lua_State *L, const char *name)
{
  return lua_getfield(L, LUA_GLOBALSINDEX, name);
}

LUA_API void lua_setglobal(lua_State *L, const char *name)
{
  lua_setfield(L, LUA_GLOBALSINDEX, name);
}

LUA_API lua_Number lua_version(lua_State *L)
{
  UNUSED(L);
  return (lua_Number)LUA_VERSION_NUM;
}

LUA_API int lua_getfield(lua_State *L, int idx, const char *k)
{
  cTValue *v, *t = index2adr_check(L, idx);
  TValue key;
  setstrV(L, &key, lj_str_newz(L, k));
  v = lj_meta_tget(L, t, &key);
  if (v == NULL) {
    L->top += 2;
    lj_vm_call(L, L->top-2, 1+1);
    L->top -= 2+LJ_FR2;
    v = L->top+1+LJ_FR2;
  }
  copyTV(L, L->top, v);
  incr_top(L);
  return lua_type(L, -1);
}

LUA_API int lua_rawget(lua_State *L, int idx)
{
  cTValue *t = index2adr(L, idx);
  lj_checkapi(tvistab(t), "stack slot %d is not a table", idx);
  copyTV(L, L->top-1, lj_tab_get(L, tabV(t), L->top-1));
  return lua_type(L, -1);
}

LUA_API int lua_rawgeti(lua_State *L, int idx, lua_Integer n)
{
  cTValue *v, *t = index2adr(L, idx);
  TValue key;
  lj_checkapi(tvistab(t), "stack slot %d is not a table", idx);
  lj_i64_toTValue(L, &key, (int64_t)n);  /* exact int64 key; no alloc below */
  v = lj_tab_get(L, tabV(t), &key);
  copyTV(L, L->top, v);
  incr_top(L);
  return lua_type(L, -1);
}

LUA_API int lua_rawgetp(lua_State *L, int idx, const void *p)
{
  cTValue *v, *t = index2adr(L, idx);
  TValue key;
  lj_checkapi(tvistab(t), "stack slot %d is not a table", idx);
  setrawlightudV(&key, (void *)p);
  v = lj_tab_get(L, tabV(t), &key);
  copyTV(L, L->top, v);
  incr_top(L);
  return lua_type(L, -1);
}

LUA_API int lua_getmetatable(lua_State *L, int idx)
{
  cTValue *o = index2adr(L, idx);
  GCtab *mt = NULL;
  if (tvistab(o))
    mt = tabref(tabV(o)->metatable);
  else if (tvisudata(o))
    mt = tabref(udataV(o)->metatable);
  else
    mt = tabref(basemt_obj(G(L), o));
  if (mt == NULL)
    return 0;
  settabV(L, L->top, mt);
  incr_top(L);
  return 1;
}

LUALIB_API void luaL_checkversion_(lua_State *L, lua_Number ver, size_t sz)
{
  UNUSED(L);
  lj_assertL((lua_Integer)ver == LUA_VERSION_NUM && sz == LUAL_BUFFERSIZE,
	     "C library built for another Lua version");
}

LUALIB_API int luaL_getmetafield(lua_State *L, int idx, const char *field)
{
  if (lua_getmetatable(L, idx)) {
    cTValue *tv = lj_tab_getstr(tabV(L->top-1), lj_str_newz(L, field));
    if (tv && !tvisnil(tv)) {
      copyTV(L, L->top-1, tv);
      return 1;
    }
    L->top--;
  }
  return 0;
}

LUA_API void lua_getfenv(lua_State *L, int idx)
{
  cTValue *o = index2adr_check(L, idx);
  if (tvisfunc(o)) {
    settabV(L, L->top, tabref(funcV(o)->c.env));
  } else if (tvisudata(o)) {
    GCudata *ud = udataV(o);
    if (ud->udtype == UDTYPE_USERDATA) {
      {  /* The 5.1 fenv view: a table env if any (user values are 5.4's). */
	GCobj *e = gcref(ud->env);
	if (e != NULL && e->gch.gct == ~LJ_TTAB)
	  settabV(L, L->top, gco2tab(e));
	else
	  setnilV(L->top);
      }
    } else {
      settabV(L, L->top, tabref(ud->env));
    }
  } else if (tvisthread(o)) {
    settabV(L, L->top, tabref(threadV(o)->env));
  } else {
    setnilV(L->top);
  }
  incr_top(L);
}

LUA_API int lua_next(lua_State *L, int idx)
{
  cTValue *t = index2adr(L, idx);
  int more;
  lj_checkapi(tvistab(t), "stack slot %d is not a table", idx);
  more = lj_tab_next(tabV(t), L->top-1, L->top-1);
  if (more > 0) {
    incr_top(L);  /* Return new key and value slot. */
  } else if (!more) {  /* End of traversal. */
    L->top--;  /* Remove key slot. */
  } else {
    lj_err_msg(L, LJ_ERR_NEXTIDX);
  }
  return more;
}

LUA_API const char *lua_getupvalue(lua_State *L, int idx, int n)
{
  TValue *val;
  GCobj *o;
  const char *name = lj_debug_uvnamev(index2adr(L, idx), (uint32_t)(n-1), &val, &o);
  if (name) {
    if (val == NULL)  /* 5.4 debug view: _ENV is the function's env table. */
      settabV(L, L->top, tabref(gco2func(o)->l.env));
    else
      copyTV(L, L->top, val);
    incr_top(L);
  }
  return name;
}

/* Upvalue reference by debug index; *isenv for the synthesized _ENV. */
static GCRef *api_uvref(GCfunc *fn, uint32_t n, int *isenv)
{
  uint32_t ei = lj_debug_envuv(fn);
  *isenv = 0;
  if (ei != ~0u) {
    if (n == ei) { *isenv = 1; return &fn->l.env; }
    if (n > ei) n--;
  }
  return &fn->l.uvptr[n];
}

LUA_API void *lua_upvalueid(lua_State *L, int idx, int n)
{
  GCfunc *fn = funcV(index2adr(L, idx));
  int isenv;
  n--;
  lj_checkapi((uint32_t)n < lj_debug_nupvalues(fn), "bad upvalue %d", n);
  return isluafunc(fn) ? (void *)gcref(*api_uvref(fn, (uint32_t)n, &isenv)) :
			 (void *)&fn->c.upvalue[n];
}

LUA_API void lua_upvaluejoin(lua_State *L, int idx1, int n1, int idx2, int n2)
{
  GCfunc *fn1 = funcV(index2adr(L, idx1));
  GCfunc *fn2 = funcV(index2adr(L, idx2));
  GCRef *r1, *r2;
  int e1, e2;
  n1--; n2--;
  lj_checkapi(isluafunc(fn1), "stack slot %d is not a Lua function", idx1);
  lj_checkapi(isluafunc(fn2), "stack slot %d is not a Lua function", idx2);
  lj_checkapi((uint32_t)n1 < lj_debug_nupvalues(fn1), "bad upvalue %d", n1+1);
  lj_checkapi((uint32_t)n2 < lj_debug_nupvalues(fn2), "bad upvalue %d", n2+1);
  r1 = api_uvref(fn1, (uint32_t)n1, &e1);
  r2 = api_uvref(fn2, (uint32_t)n2, &e2);
  lj_debug_uvjoin(L, fn1, r1, e1, fn2, r2, e2);
}

LUALIB_API void *luaL_testudata(lua_State *L, int idx, const char *tname)
{
  cTValue *o = index2adr(L, idx);
  if (tvisudata(o)) {
    GCudata *ud = udataV(o);
    cTValue *tv = lj_tab_getstr(tabV(registry(L)), lj_str_newz(L, tname));
    if (tv && tvistab(tv) && tabV(tv) == tabref(ud->metatable))
      return uddata(ud);
  }
  return NULL;  /* value is not a userdata with a metatable */
}

LUALIB_API void *luaL_checkudata(lua_State *L, int idx, const char *tname)
{
  void *p = luaL_testudata(L, idx, tname);
  if (!p) lj_err_argtype(L, idx, tname);
  return p;
}

/* -- Object setters ------------------------------------------------------ */

LUA_API void lua_settable(lua_State *L, int idx)
{
  TValue *o;
  cTValue *t = index2adr_check(L, idx);
  lj_checkapi_slot(2);
  o = lj_meta_tset(L, t, L->top-2);
  if (o) {
    /* NOBARRIER: lj_meta_tset ensures the table is not black. */
    L->top -= 2;
    copyTV(L, o, L->top+1);
  } else {
    TValue *base = L->top;
    copyTV(L, base+2, base-3-2*LJ_FR2);
    L->top = base+3;
    lj_vm_call(L, base, 0+1);
    L->top -= 3+LJ_FR2;
  }
}

LUA_API void lua_setfield(lua_State *L, int idx, const char *k)
{
  TValue *o;
  TValue key;
  cTValue *t = index2adr_check(L, idx);
  lj_checkapi_slot(1);
  setstrV(L, &key, lj_str_newz(L, k));
  o = lj_meta_tset(L, t, &key);
  if (o) {
    /* NOBARRIER: lj_meta_tset ensures the table is not black. */
    copyTV(L, o, --L->top);
  } else {
    TValue *base = L->top;
    copyTV(L, base+2, base-3-2*LJ_FR2);
    L->top = base+3;
    lj_vm_call(L, base, 0+1);
    L->top -= 2+LJ_FR2;
  }
}

LUA_API void lua_rawset(lua_State *L, int idx)
{
  GCtab *t = tabV(index2adr(L, idx));
  TValue *dst, *key;
  lj_checkapi_slot(2);
  key = L->top-2;
  dst = lj_tab_set(L, t, key);
  copyTV(L, dst, key+1);
  lj_gc_anybarriert(L, t);
  L->top = key;
}

LUA_API void lua_rawseti(lua_State *L, int idx, lua_Integer n)
{
  GCtab *t = tabV(index2adr(L, idx));
  TValue key;
  TValue *dst;
  lj_checkapi_slot(1);
  if ((int64_t)n == (int64_t)(int32_t)n) {
    setintV(&key, (int32_t)n);
    dst = lj_tab_set(L, t, &key);
    copyTV(L, dst, L->top-1);
    lj_gc_barriert(L, t, dst);
    L->top--;
  } else {
    /* Exact boxed key, rooted on the stack during the (allocating) set. */
    api_pushkey(L, n);
    dst = lj_tab_set(L, t, L->top-1);
    copyTV(L, dst, L->top-2);
    lj_gc_barriert(L, t, dst);
    L->top -= 2;
  }
}

LUA_API void lua_rawsetp(lua_State *L, int idx, const void *p)
{
  GCtab *t = tabV(index2adr(L, idx));
  TValue key;
  TValue *dst;
  lj_checkapi_slot(1);
  setrawlightudV(&key, (void *)p);
  dst = lj_tab_set(L, t, &key);
  copyTV(L, dst, L->top-1);
  lj_gc_barriert(L, t, dst);
  L->top--;
}

LUA_API int lua_setmetatable(lua_State *L, int idx)
{
  global_State *g;
  GCtab *mt;
  cTValue *o = index2adr_check(L, idx);
  lj_checkapi_slot(1);
  if (tvisnil(L->top-1)) {
    mt = NULL;
  } else {
    lj_checkapi(tvistab(L->top-1), "top stack slot is not a table");
    mt = tabV(L->top-1);
  }
  g = G(L);
  if (tvistab(o)) {
    setgcref(tabV(o)->metatable, obj2gco(mt));
    if (mt)
      lj_gc_objbarriert(L, tabV(o), mt);
  } else if (tvisudata(o)) {
    setgcref(udataV(o)->metatable, obj2gco(mt));
    if (mt)
      lj_gc_objbarrier(L, udataV(o), mt);
  } else {
    /* Flush cache, since traces specialize to basemt. But not during __gc. */
    if (lj_trace_flushall(L))
      lj_err_caller(L, LJ_ERR_NOGCMM);
    o = index2adr(L, idx);  /* Stack may have been reallocated. */
    if (tvisbool(o)) {
      /* NOBARRIER: basemt is a GC root. */
      setgcref(basemt_it(g, LJ_TTRUE), obj2gco(mt));
      setgcref(basemt_it(g, LJ_TFALSE), obj2gco(mt));
    } else {
      /* NOBARRIER: basemt is a GC root. */
      setgcref(basemt_obj(g, o), obj2gco(mt));
    }
  }
  L->top--;
  return 1;
}

LUALIB_API void luaL_setmetatable(lua_State *L, const char *tname)
{
  lua_getfield(L, LUA_REGISTRYINDEX, tname);
  lua_setmetatable(L, -2);
}

LUA_API int lua_setfenv(lua_State *L, int idx)
{
  cTValue *o = index2adr_check(L, idx);
  GCtab *t;
  lj_checkapi_slot(1);
  lj_checkapi(tvistab(L->top-1), "top stack slot is not a table");
  t = tabV(L->top-1);
  if (tvisfunc(o)) {
    setgcref(funcV(o)->c.env, obj2gco(t));
  } else if (tvisudata(o)) {
    GCudata *ud = udataV(o);
    setgcref(ud->env, obj2gco(t));
  } else if (tvisthread(o)) {
    setgcref(threadV(o)->env, obj2gco(t));
  } else {
    L->top--;
    return 0;
  }
  lj_gc_objbarrier(L, gcV(o), t);
  L->top--;
  return 1;
}

LUA_API int lua_getiuservalue(lua_State *L, int idx, int n)
{
  cTValue *o = index2adr(L, idx);
  lj_checkapi_slot(1);
  GCudata *ud;
  lj_checkapi(tvisudata(o), "stack slot %d is not a userdata", idx);
  ud = udataV(o);
  if (n <= 0 || (MSize)n > ud->nuvalue) {
    setnilV(L->top);
    incr_top(L);
    return LUA_TNONE;
  }
  copyTV(L, L->top, &uduvs(ud)[n-1]);
  incr_top(L);
  return lua_type(L, -1);
}

LUA_API int lua_setiuservalue(lua_State *L, int idx, int n)
{
  cTValue *o = index2adr(L, idx);
  GCudata *ud;
  int res = 0;
  lj_checkapi_slot(1);
  lj_checkapi(tvisudata(o), "stack slot %d is not a userdata", idx);
  ud = udataV(o);
  if (n > 0 && (MSize)n <= ud->nuvalue) {
    TValue *uv = &uduvs(ud)[n-1];
    cTValue *v = L->top-1;
    copyTV(L, uv, v);  /* Any value (5.4), also non-GC ones. */
    /* Userdata are marked black at once: forward barrier for a white value. */
    if (tvisgcv(v)) lj_gc_objbarrier(L, ud, gcV(v));
    res = 1;
  }
  L->top--;  /* PUC always pops the value, also for an out-of-range n. */
  return res;
}

LUA_API const char *lua_setupvalue(lua_State *L, int idx, int n)
{
  cTValue *f = index2adr(L, idx);
  TValue *val;
  GCobj *o;
  const char *name;
  lj_checkapi_slot(1);
  name = lj_debug_uvnamev(f, (uint32_t)(n-1), &val, &o);
  if (name) {
    L->top--;
    if (val == NULL) {  /* 5.4 debug view: set the env (a table here). */
      if (!tvistab(L->top)) return NULL;
      setgcref(gco2func(o)->l.env, obj2gco(tabV(L->top)));
      lj_gc_objbarrier(L, o, tabV(L->top));
    } else {
      copyTV(L, val, L->top);
      lj_gc_barrier(L, o, L->top);
    }
  }
  return name;
}

/* -- Calls --------------------------------------------------------------- */

#if LJ_FR2
static TValue *api_call_base(lua_State *L, int nargs)
{
  TValue *o = L->top, *base = o - nargs;
  L->top = o+1;
  for (; o > base; o--) copyTV(L, o, o-1);
  setnilV(o);
  return o+1;
}
#else
#define api_call_base(L, nargs)	(L->top - (nargs))
#endif

LUA_API void lua_call(lua_State *L, int nargs, int nresults)
{
  lj_checkapi(L->status == LUA_OK || L->status == LUA_ERRERR,
	      "thread called in wrong state %d", L->status);
  lj_checkapi_slot(nargs+1);
  lj_vm_call(L, api_call_base(L, nargs), nresults+1);
}

/* Lua 5.4 continuation variants. LuaJIT has no C-level continuation frames,
** so k is never invoked: callk/pcallk behave exactly like call/pcall. */
LUA_API void lua_callk(lua_State *L, int nargs, int nresults,
		       lua_KContext ctx, lua_KFunction k)
{
  UNUSED(ctx); UNUSED(k);
  lua_call(L, nargs, nresults);
}

LUA_API int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc)
{
  global_State *g = G(L);
  uint8_t oldh = hook_save(g);
  ptrdiff_t ef;
  int status;
  lj_checkapi(L->status == LUA_OK || L->status == LUA_ERRERR,
	      "thread called in wrong state %d", L->status);
  lj_checkapi_slot(nargs+1);
  if (errfunc == 0) {
    ef = 0;
  } else {
    cTValue *o = index2adr_stack(L, errfunc);
    ef = savestack(L, o);
  }
  status = lj_vm_pcall(L, api_call_base(L, nargs), nresults+1, ef);
  if (status) hook_restore(g, oldh);
  return status;
}

LUA_API int lua_pcallk(lua_State *L, int nargs, int nresults, int errfunc,
		       lua_KContext ctx, lua_KFunction k)
{
  int status;
  UNUSED(ctx); UNUSED(k);
  status = lua_pcall(L, nargs, nresults, errfunc);
  if (status == LUA_YIELD) {
    /* Not reachable: lua_pcall never returns LUA_YIELD. If it ever did, a
    ** throw here would unwind an unprotected API call, so report instead. */
    lua_pushliteral(L, "attempt to yield across a C-call boundary");
    return LUA_ERRRUN;
  }
  return status;
}

static TValue *cpcall(lua_State *L, lua_CFunction func, void *ud)
{
  GCfunc *fn = lj_func_newC(L, 0, getcurrenv(L));
  TValue *top = L->top;
  fn->c.f = func;
  setfuncV(L, top++, fn);
  if (LJ_FR2) setnilV(top++);
#if LJ_64
  ud = lj_lightud_intern(L, ud);
#endif
  setrawlightudV(top++, ud);
  cframe_nres(L->cframe) = 1+0;  /* Zero results. */
  L->top = top;
  return top-1;  /* Now call the newly allocated C function. */
}

LUA_API int lua_cpcall(lua_State *L, lua_CFunction func, void *ud)
{
  global_State *g = G(L);
  uint8_t oldh = hook_save(g);
  int status;
  lj_checkapi(L->status == LUA_OK || L->status == LUA_ERRERR,
	      "thread called in wrong state %d", L->status);
  status = lj_vm_cpcall(L, func, ud, cpcall);
  if (status) hook_restore(g, oldh);
  return status;
}

LUALIB_API int luaL_callmeta(lua_State *L, int idx, const char *field)
{
  if (luaL_getmetafield(L, idx, field)) {
    TValue *top = L->top--;
    if (LJ_FR2) setnilV(top++);
    copyTV(L, top++, index2adr(L, idx));
    L->top = top;
    lj_vm_call(L, top-1, 1+1);
    return 1;
  }
  return 0;
}

/* -- Coroutine yield and resume ------------------------------------------ */

LUA_API int lua_isyieldable(lua_State *L)
{
  return cframe_canyield(L->cframe);
}

LUA_API int lua_yield(lua_State *L, int nresults)
{
  void *cf = L->cframe;
  global_State *g = G(L);
  if (cframe_canyield(cf)) {
    cf = cframe_raw(cf);
    if (!hook_active(g)) {  /* Regular yield: move results down if needed. */
      cTValue *f = L->top - nresults;
      if (f > L->base) {
	TValue *t = L->base;
	while (--nresults >= 0) copyTV(L, t++, f++);
	L->top = t;
      }
      L->cframe = NULL;
      L->status = LUA_YIELD;
      return -1;
    } else {  /* Yield from hook: add a pseudo-frame. */
      TValue *top = L->top;
      hook_leave(g);
      (top++)->u64 = cframe_multres(cf);
      setcont(top, lj_cont_hook);
      if (LJ_FR2) top++;
      setframe_pc(top, cframe_pc(cf)-1);
      top++;
      setframe_gc(top, obj2gco(L), LJ_TTHREAD);
      if (LJ_FR2) top++;
      setframe_ftsz(top, ((char *)(top+1)-(char *)L->base)+FRAME_CONT);
      L->top = L->base = top+1;
#if ((defined(__GNUC__) || defined(__clang__)) && (LJ_TARGET_X64 || defined(LUAJIT_UNWIND_EXTERNAL)) && !LJ_NO_UNWIND) || LJ_TARGET_WINDOWS
      lj_err_throw(L, LUA_YIELD);
#else
      L->cframe = NULL;
      L->status = LUA_YIELD;
      lj_vm_unwind_c(cf, LUA_YIELD);
#endif
    }
  }
  /* 5.4 wording: inside a coroutine the yield is blocked by a C-call
  ** boundary (pcall of a C function, a sort/gsub callback); only the main
  ** thread is "outside a coroutine". */
  lj_err_msg(L, L != mainthread(g) ? LJ_ERR_CYIELDK : LJ_ERR_CYIELD);
  return 0;  /* unreachable */
}

/* Lua 5.4 lua_yieldk: k == NULL is plain lua_yield. A non-NULL continuation
** cannot be called after a resume in LuaJIT, so yielding with one is refused
** instead of silently skipping the continuation. */
LUA_API int lua_yieldk(lua_State *L, int nresults, lua_KContext ctx,
		       lua_KFunction k)
{
  UNUSED(ctx);
  if (k != NULL) {
    if (L != mainthread(G(L)))
      lj_err_msg(L, LJ_ERR_CYIELDK);
    else
      lj_err_msg(L, LJ_ERR_CYIELD);
  }
  return lua_yield(L, nresults);
}

/* Lua 5.4 signature: from is the resuming thread (ignored here; LuaJIT resumes
** on the state itself) and *nres receives the number of results. */
LUA_API int lua_resume(lua_State *L, lua_State *from, int nargs, int *nres)
{
  int st;
  UNUSED(from);
  if (nres) *nres = 0;
  if (L->cframe == NULL && L->status <= LUA_YIELD) {
    st = lj_vm_resume(L,
      L->status == LUA_OK ? api_call_base(L, nargs) : L->top - nargs,
      0, 0);
    if (nres && (st == LUA_OK || st == LUA_YIELD))
      *nres = (int)(L->top - L->base);
    return st;
  }
  L->top = L->base;
  setstrV(L, L->top, lj_err_str(L, LJ_ERR_COSUSP));
  incr_top(L);
  return LUA_ERRRUN;
}

/* Lua 5.4 thread reset: close pending to-be-closed slots and upvalues, then
** put the thread back to its fresh suspended state. The PUC 'from' argument
** only feeds PUC's C-call counter; LuaJIT keeps no such per-thread counter. */
LUA_API int lua_closethread(lua_State *L, lua_State *from)
{
  int status = L->status, st;
  TValue *eslot;
  UNUSED(from);
  lj_checkapi(L->cframe == NULL, "thread is running");
  if (status == LUA_YIELD) status = LUA_OK;
  eslot = L->top++;
  if (status != LUA_OK && L->top-1 > L->base)
    copyTV(L, eslot, L->top-2);
  else
    setnilV(eslot);
  L->status = LUA_OK;
  st = lj_meta_tbccloseall(L, tvref(L->stack), eslot);
  eslot = L->top-1;  /* close calls may grow the stack */
  lj_func_closeuv(L, tvref(L->stack));
  L->base = L->top = tvref(L->stack) + 1 + LJ_FR2;
  L->cframe = NULL;
  L->errnest = 0;
  L->errnestofs = 0;
  if (st != LUA_OK) {  /* keep the error object for the caller */
    copyTV(L, L->base, eslot);
    L->top = L->base+1;
    return st;
  }
  return LUA_OK;
}

LUA_API int lua_resetthread(lua_State *L)
{
  return lua_closethread(L, NULL);
}

/* -- GC and memory management -------------------------------------------- */

LUA_API int lua_gc(lua_State *L, int what, int data)
{
  global_State *g = G(L);
  int res = 0;
  switch (what) {
  case LUA_GCSTOP:
    g->gc.threshold = LJ_MAX_MEM;
    break;
  case LUA_GCRESTART:
    g->gc.threshold = data == -1 ? (g->gc.total/100)*g->gc.pause : g->gc.total;
    break;
  case LUA_GCCOLLECT:
    lj_gc_fullgc(L);
    break;
  case LUA_GCCOUNT:
    res = (int)(g->gc.total >> 10);
    break;
  case LUA_GCCOUNTB:
    res = (int)(g->gc.total & 0x3ff);
    break;
  case LUA_GCSTEP: {
    GCSize a = (GCSize)data << 10;
    g->gc.threshold = (a <= g->gc.total) ? (g->gc.total - a) : 0;
    while (g->gc.total >= g->gc.threshold)
      if (lj_gc_step(L) > 0) {
	res = 1;
	break;
      }
    break;
  }
  case LUA_GCSETPAUSE:
    res = (int)(g->gc.pause);
    g->gc.pause = (MSize)data;
    break;
  case LUA_GCSETSTEPMUL:
    res = (int)(g->gc.stepmul);
    g->gc.stepmul = (MSize)data;
    break;
  case LUA_GCISRUNNING:
    res = (g->gc.threshold != LJ_MAX_MEM);
    break;
  case LUA_GCGEN: case LUA_GCINC: {
    /* 5.4 returns the previous mode; LuaJIT keeps a single collector but
    ** reports the mode switch faithfully. */
    int prev = g->gc.gcmode ? LUA_GCGEN : LUA_GCINC;
    g->gc.gcmode = what == LUA_GCGEN;
    res = prev;
    break;
    }
  default:
    res = -1;  /* Invalid option. */
  }
  return res;
}

LUA_API lua_Alloc lua_getallocf(lua_State *L, void **ud)
{
  global_State *g = G(L);
  if (ud) *ud = g->allocd;
  return g->allocf;
}

LUA_API void lua_setallocf(lua_State *L, lua_Alloc f, void *ud)
{
  global_State *g = G(L);
  g->allocd = ud;
  g->allocf = f;
}

