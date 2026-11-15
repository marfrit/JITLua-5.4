/*
** Boxed interned 64-bit integers (ADR-001b, LuaJIT-5.4 port).
** See docs/adr-001b-boxed-i64.md.
**
** A Lua 5.4 integer that does not fit into int32 becomes an immutable GCudata
** holding one int64_t, with a private udtype (UDTYPE_I64BOX) as the marker.
** No new GC tag is used: the GC64 tag encoding drops a tag's bit 0 in the
** VM's 17-bit form, so a new tag (and even moving LJ_TNUMX) breaks agreement
** between the C side and the interpreter -- measured.
**
** The objects are interned in a table anchored in the registry: keys are the
** 8 raw bytes of the value (as an interned binary string), values are the
** objects. Interning makes pointer equality equal to value equality, which
** keeps raw comparison, table keys and the same-type GC-pointer compares
** correct without new compare code on the fast paths.
**
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#define lj_i64_c
#define LUA_CORE

#include <math.h>

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_udata.h"
#include "lj_state.h"
#include "lj_bc.h"
#include "lj_vm.h"

#include "lj_i64.h"

#define I64_MIN ((int64_t)(-0x7fffffffffffffffLL - 1))

int LJ_FASTCALL lj_i64_isnum(cTValue *o)
{
  return tvisi64(o);
}

int LJ_FASTCALL lj_i64_getint(cTValue *o, int64_t *p)
{
#if LJ_GC64
  if (tvisi47w(o)) {  /* widened 47-bit inline integer (step 6) */
    *p = intV47(o);
    return 1;
  }
#endif
  if (tvisint(o)) {
    *p = (int64_t)intV(o);
    return 1;
  } else if (tvisi64(o)) {
    *p = i64V(o);
    return 1;
  }
  return 0;
}

/* -- Intern hash (ADR-001b step 1) --------------------------------------- */
/* A dedicated open-addressing hash keyed by the int64 value. Entries are weak:
** the table is not a GC root, so a box is collected normally and the sweep
** removes its entry (lj_i64_remove). Tombstones (GCRef bits == 1) keep probe
** chains intact; empty slots hold NULL. */

#define I64_HSIZE_MIN	64
#define I64_TOMB		((uintptr_t)1)

static LJ_AINLINE uint32_t i64_hash(int64_t v)
{
  uint64_t u = (uint64_t)v * 0x9e3779b97f4a7c15ULL;
  return (uint32_t)(u >> 32);
}

static void i64_resize(lua_State *L, MSize size)
{
  global_State *g = G(L);
  GCRef *newtab = (GCRef *)lj_mem_new(L, (GCSize)(size * sizeof(GCRef)));
  MSize i;
  for (i = 0; i < size; i++) setgcrefnull(newtab[i]);
  if (g->i64.tab) {
    MSize mask = g->i64.mask;
    for (i = 0; i <= mask; i++) {
      uintptr_t u = gcrefu(g->i64.tab[i]);
      GCobj *o;
      if (u == 0 || u == I64_TOMB) continue;
      o = (GCobj *)(uintptr_t)u;
      {
	uint32_t h = i64_hash(*(int64_t *)uddata(gco2ud(o))) & (size-1);
	while (gcrefu(newtab[h]) != 0) h = (h + 1) & (size-1);
	setgcref(newtab[h], o);
      }
    }
    lj_mem_free(g, g->i64.tab, (mask+1) * sizeof(GCRef));
  }
  g->i64.tab = newtab;
  g->i64.mask = size-1;
}

void LJ_FASTCALL lj_i64_remove(global_State *g, GCudata *ud)
{
  int64_t v = *(int64_t *)uddata(ud);
  MSize mask = g->i64.mask, h = i64_hash(v) & mask, i;
  /* Find the entry for this object. */
  for (i = h; ; i = (i + 1) & mask) {
    GCRef r = g->i64.tab[i];
    uintptr_t u = gcrefu(r);
    if (u == 0) return;  /* not interned (should not happen) */
    if (u != I64_TOMB && (GCobj *)(uintptr_t)u == obj2gco(ud)) break;
  }
  setgcrefp(g->i64.tab[i], (void *)(uintptr_t)I64_TOMB);
  g->i64.num--;
}

GCudata *lj_i64_box(lua_State *L, int64_t v)
{
  global_State *g = G(L);
  if (g->i64.tab) {
    MSize mask = g->i64.mask, h = i64_hash(v) & mask, i;
    for (i = h; ; i = (i + 1) & mask) {
      uintptr_t u = gcrefu(g->i64.tab[i]);
      if (u == 0) break;  /* empty slot: not interned */
      if (u != I64_TOMB && *(int64_t *)uddata(gco2ud((GCobj *)(uintptr_t)u)) == v)
	return gco2ud((GCobj *)(uintptr_t)u);
    }
  }
  {
    /* Userdata must never have a NULL env: gc_mark() unconditionally marks it. */
    GCudata *ud = lj_udata_new(L, sizeof(int64_t), tabref(L->env));
    ud->udtype = UDTYPE_I64BOX;
    *(int64_t *)uddata(ud) = v;
    /* Insert (rehash if the table is getting full). */
    if (!g->i64.tab || g->i64.num >= (g->i64.mask+1) * 3 / 4)
      i64_resize(L, g->i64.tab ? (g->i64.mask+1) * 2 : I64_HSIZE_MIN);
    {
      MSize mask = g->i64.mask, h = i64_hash(v) & mask;
      while (gcrefu(g->i64.tab[h]) != 0 && gcrefu(g->i64.tab[h]) != I64_TOMB)
	h = (h + 1) & mask;
      setgcref(g->i64.tab[h], obj2gco(ud));
      g->i64.num++;
    }
    return ud;
  }
}

void LJ_FASTCALL lj_i64_freetab(global_State *g)
{
  if (g->i64.tab) {
    lj_mem_freevec(g, g->i64.tab, g->i64.mask+1, GCRef);
    g->i64.tab = NULL;
    g->i64.mask = 0;
    g->i64.num = 0;
  }
}

void lj_i64_push(lua_State *L, int64_t v)
{
  ptrdiff_t ofs = L->top - L->base;  /* the box allocation may move the stack */
  GCudata *ud = lj_i64_box(L, v);
  setudataV(L, L->base + ofs, ud);
  incr_top(L);
}

/* -- C semantics helper (ADR-001b steps 2-3) ------------------------------ */

/* Store an integer result: int32 inline when it fits, otherwise boxed.
** Boxing allocates and a GC allocation may grow (move) the Lua stack, which
** would invalidate the destination pointer the VM handed us -- measured on x64.
** Store through a base-relative offset instead. */
void LJ_FASTCALL lj_i64_toTValue(lua_State *L, TValue *ra, int64_t v)
{
  if ((int64_t)(int32_t)v == v) {
    setintV(ra, (int32_t)v);
#if LJ_GC64 /* step-6 activation. The widened inline form is distinguishable
       ** from an int32 only while payload bits 32..46 are nonzero: values in
       **[2^31, 2^32) encode as p=0 and would read back as the signed int32 of
       ** their low word, so they stay boxed (narrow band, documented). */
  } else if (i47_fits(v) && (((uint64_t)v >> 32) & 0x7fffu) != 0) {
    setint47V(ra, v);
#endif
  } else {
    ptrdiff_t ofs = ra - L->base;
    GCudata *ud = lj_i64_box(L, v);
    setudataV(L, L->base + ofs, ud);
  }
}

#define i64_store(L, ra, v)	lj_i64_toTValue((L), (ra), (v))

/* Integer floor division: wraps like 5.4 (INT64_MIN // -1 == INT64_MIN). */
static int64_t i64_idiv(lua_State *L, int64_t a, int64_t b)
{
  if (b == 0) lj_err_msg(L, LJ_ERR_IDIVZ);
  if (a == I64_MIN && b == -1) return a;
  {
    int64_t q = a / b;
    if ((a % b) != 0 && ((a < 0) != (b < 0)))
      q -= 1;
    return q;
  }
}

/* Integer floor modulo: the result takes the sign of the divisor. */
static int64_t i64_mod(lua_State *L, int64_t a, int64_t b)
{
  if (b == 0) lj_err_msg(L, LJ_ERR_MODZ);
  if (a == I64_MIN && b == -1) return 0;
  {
    int64_t r = a % b;
    if (r != 0 && ((r < 0) != (b < 0)))
      r += b;
    return r;
  }
}

/* 5.4 shifts: a count of 64 or more yields 0; a negative count reverses the
** direction; shift right is logical (unsigned). */
static int64_t i64_shift(int64_t a, int64_t n, int right)
{
  uint64_t u = (uint64_t)a;
  uint64_t cnt;
  if (n < 0) {
    right = !right;
    cnt = (uint64_t)0 - (uint64_t)n;
  } else {
    cnt = (uint64_t)n;
  }
  if (cnt >= 64) return 0;
  if (right)
    return (int64_t)((cnt == 0) ? u : (u >> cnt));
  else
    return (int64_t)((cnt == 0) ? u : (u << cnt));
}

/* Float semantics for the mixed int/float and float cases of the same ops. */
static void i64_floatop(lua_State *L, TValue *ra, lua_Number a, lua_Number b,
			I64Op op)
{
  switch (op) {
  case I64_ADD: setnumV(ra, a + b); break;
  case I64_SUB: setnumV(ra, a - b); break;
  case I64_MUL: setnumV(ra, a * b); break;
  case I64_DIV: setnumV(ra, a / b); break;
  case I64_POW: setnumV(ra, lj_vm_foldarith(a, b, (int)MM_pow - (int)MM_add));
    return;
  case I64_MOD:  /* float % is floor-mod in 5.4 too */
    if (b == 0) setnumV(ra, a / b * 0);  /* nan, as in Lua */
    else setnumV(ra, a - floor(a / b) * b);
    break;
  case I64_IDIV:
    setnumV(ra, floor(a / b));
    break;
  default:
    setnumV(ra, a);  /* unreachable for binary ops */
    break;
  }
}

int LJ_FASTCALL lj_i64_arith(lua_State *L, TValue *ra, cTValue *rb,
			     cTValue *rc, I64Op op)
{
  int64_t a, b;
  int ia = lj_i64_getint(rb, &a), ib = lj_i64_getint(rc, &b);
  if (ia && ib) {  /* Integer domain: 5.4 64-bit wrap semantics. */
    switch (op) {
    case I64_ADD: i64_store(L, ra, (int64_t)((uint64_t)a + (uint64_t)b)); break;
    case I64_SUB: i64_store(L, ra, (int64_t)((uint64_t)a - (uint64_t)b)); break;
    case I64_MUL: i64_store(L, ra, (int64_t)((uint64_t)a * (uint64_t)b)); break;
    case I64_DIV: setnumV(ra, (lua_Number)a / (lua_Number)b); break;  /* / is float */
    case I64_POW:
      setnumV(ra, lj_vm_foldarith((lua_Number)a, (lua_Number)b,
				  (int)MM_pow - (int)MM_add));
      break;
    case I64_MOD: i64_store(L, ra, i64_mod(L, a, b)); break;
    case I64_IDIV: i64_store(L, ra, i64_idiv(L, a, b)); break;
    case I64_BAND: i64_store(L, ra, (int64_t)((uint64_t)a & (uint64_t)b)); break;
    case I64_BOR: i64_store(L, ra, (int64_t)((uint64_t)a | (uint64_t)b)); break;
    case I64_BXOR: i64_store(L, ra, (int64_t)((uint64_t)a ^ (uint64_t)b)); break;
    case I64_SHL: i64_store(L, ra, i64_shift(a, b, 0)); break;
    case I64_SHR: i64_store(L, ra, i64_shift(a, b, 1)); break;
    default: return 0;
    }
    return 1;
  }
  /* Mixed or float: numeric comparison semantics need both to be numbers. */
  if (tvisnumber(rb) && tvisnumber(rc)) {
    i64_floatop(L, ra, numberVnum(rb), numberVnum(rc), op);
    return 1;
  }
  return 0;  /* Let the caller handle strings, metamethods and errors. */
}

int LJ_FASTCALL lj_i64_unop(lua_State *L, TValue *ra, cTValue *rb, I64Op op)
{
  int64_t a;
  if (lj_i64_getint(rb, &a)) {
    if (op == I64_UNM) {
      i64_store(L, ra, (int64_t)((uint64_t)0 - (uint64_t)a));
      return 1;
    } else if (op == I64_BNOT) {
      i64_store(L, ra, (int64_t)(~(uint64_t)a));
      return 1;
    }
    return 0;
  }
  if (tvisnumber(rb)) {
    if (op == I64_UNM) {
      setnumV(ra, -numberVnum(rb));
      return 1;
    }
    return 0;  /* bnot of a float: let the caller raise */
  }
  return 0;
}

int LJ_FASTCALL lj_i64_compare(cTValue *a, cTValue *b, int op, int *res)
{
  int64_t ia, ib;
  int ka = lj_i64_getint(a, &ia), kb = lj_i64_getint(b, &ib);
  if (ka && kb) {  /* Both integers: exact 64-bit comparison. */
    *res = (op == 0) ? (ia == ib) : (op == 1) ? (ia < ib) : (ia <= ib);
    return 1;
  }
  /* int64 against a float: compare mathematically exactly via long double
  ** (aarch64/x86-64 long double has a 64-bit mantissa, so int64 is exact). */
  if ((ka || kb) && (tvisnumber(a) || tvisnumber(b))) {
    long double x = ka ? (long double)ia : (long double)numberVnum(a);
    long double y = kb ? (long double)ib : (long double)numberVnum(b);
    *res = (op == 0) ? (x == y) : (op == 1) ? (x < y) : (x <= y);
    return 1;
  }
  return 0;
}

/* Arithmetic metamethod -> helper operation (only the ops the helper covers). */
I64Op lj_i64_op_from_mm(MMS mm)
{
  switch (mm) {
  case MM_add: return I64_ADD;
  case MM_sub: return I64_SUB;
  case MM_mul: return I64_MUL;
  case MM_div: return I64_DIV;
  case MM_mod: return I64_MOD;
  case MM_pow: return I64_POW;
  case MM_unm: return I64_UNM;
  case MM_idiv: return I64_IDIV;
  default: return I64__MAX;
  }
}

/* 5.4 bitwise ops: integer operands (int32 or boxed int64) and floats with an
** exact integer representation. Returns 1 when handled (result in *ra). */
int LJ_FASTCALL lj_i64_bitop(lua_State *L, TValue *ra, cTValue *rb,
			     cTValue *rc, BCReg op)
{
  int64_t b, c;
  int okb, okc;
  if (lj_i64_getint(rb, &b)) {
    okb = 1;
  } else if (tvisnum(rb)) {
    b = lj_num2i64(numV(rb));
    if ((lua_Number)b != numV(rb)) lj_err_msg(L, LJ_ERR_NUMNOINT);
    okb = 1;
  } else {
    okb = 0;
  }
  if (okb && lj_i64_getint(rc, &c)) {
    okc = 1;
  } else if (okb && tvisnum(rc)) {
    c = lj_num2i64(numV(rc));
    if ((lua_Number)c != numV(rc)) lj_err_msg(L, LJ_ERR_NUMNOINT);
    okc = 1;
  } else {
    okc = 0;
  }
  if (!(okb && okc)) return 0;  /* caller reports the offending operand */
  {
    int64_t v;
    switch (op) {
    case BC_BAND: v = (int64_t)((uint64_t)b & (uint64_t)c); break;
    case BC_BNOT: v = (int64_t)(~(uint64_t)b); break;
    case BC_BOR: v = (int64_t)((uint64_t)b | (uint64_t)c); break;
    case BC_BXOR: v = (int64_t)((uint64_t)b ^ (uint64_t)c); break;
    case BC_BSHL: v = i64_shift(b, c, 0); break;
    case BC_BSHR: v = i64_shift(b, c, 1); break;
    case BC_BSAR: {  /* LuaJIT extension: arithmetic shift */
      uint64_t cnt = (c < 0) ? (uint64_t)0 - (uint64_t)c : (uint64_t)c;
      if (cnt >= 64) v = (b < 0) ? -1 : 0;
      else v = (cnt == 0) ? b : (b >> (int)cnt);
      break;
      }
    default: return 0;
    }
    i64_store(L, ra, v);
    return 1;
  }
}
