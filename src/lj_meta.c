/*
** Metamethod handling.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lj_meta_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_meta.h"
#include "lj_frame.h"
#include "lj_bc.h"
#include "lj_vm.h"
#include <math.h>
#include "lj_strscan.h"
#include "lj_strfmt.h"
#include "lj_lib.h"
#include "lj_debug.h"
#include "lj_state.h"
#include "lj_i64.h"
#include "lj_dispatch.h"
#include "lj_udata.h"
#if LJ_HASFFI
#include "lj_ctype.h"
#include "lj_cdata.h"
#include "lj_carith.h"
#endif

/* -- Metamethod handling ------------------------------------------------- */

/* String interning of metamethod names for fast indexing. */
void lj_meta_init(lua_State *L)
{
#define MMNAME(name)	"__" #name
  const char *metanames = MMDEF(MMNAME);
#undef MMNAME
  global_State *g = G(L);
  const char *p, *q;
  uint32_t mm;
  for (mm = 0, p = metanames; *p; mm++, p = q) {
    GCstr *s;
    for (q = p+2; *q && *q != '_'; q++) ;
    s = lj_str_new(L, p, (size_t)(q-p));
    /* NOBARRIER: g->gcroot[] is a GC root. */
    setgcref(g->gcroot[GCROOT_MMNAME+mm], obj2gco(s));
  }
}

/* Negative caching of a few fast metamethods. See the lj_meta_fast() macro. */
cTValue *lj_meta_cache(GCtab *mt, MMS mm, GCstr *name)
{
  cTValue *mo = lj_tab_getstr(mt, name);
  lj_assertX(mm <= MM_FAST, "bad metamethod %d", mm);
  if (!mo || tvisnil(mo)) {  /* No metamethod? */
    mt->nomm |= (uint8_t)(1u<<mm);  /* Set negative cache flag. */
    return NULL;
  }
  return mo;
}

/* Lookup metamethod for object. */
cTValue *lj_meta_lookup(lua_State *L, cTValue *o, MMS mm)
{
  GCtab *mt;
  if (tvistab(o))
    mt = tabref(tabV(o)->metatable);
  else if (tvisudata(o) && !tvisi64(o))  /* boxed int64 is a number */
    mt = tabref(udataV(o)->metatable);
  else
    mt = tabref(basemt_obj(G(L), o));
  if (mt) {
    cTValue *mo = lj_tab_getstr(mt, mmname_str(G(L), mm));
    if (mo)
      return mo;
    if (mm == MM_tostring)
      mt->nomm |= MM_TOSTR_ABSENT;  /* asm tostring may inline the next time */
  }
  return niltv(L);
}

#if LJ_HASFFI
/* Tailcall from C function. */
int lj_meta_tailcall(lua_State *L, cTValue *tv)
{
  TValue *base = L->base;
  TValue *top = L->top;
  const BCIns *pc = frame_pc(base-1);  /* Preserve old PC from frame. */
  copyTV(L, base-1-LJ_FR2, tv);  /* Replace frame with new object. */
  if (LJ_FR2)
    (top++)->u64 = LJ_CONT_TAILCALL;
  else
    top->u32.lo = LJ_CONT_TAILCALL;
  setframe_pc(top++, pc);
  setframe_gc(top, obj2gco(L), LJ_TTHREAD);  /* Dummy frame object. */
  if (LJ_FR2) top++;
  setframe_ftsz(top, ((char *)(top+1) - (char *)base) + FRAME_CONT);
  L->base = L->top = top+1;
  /*
  ** before:   [old_mo|PC]    [... ...]
  **                         ^base     ^top
  ** after:    [new_mo|itype] [... ...] [NULL|PC] [dummy|delta]
  **                                                           ^base/top
  ** tailcall: [new_mo|PC]    [... ...]
  **                         ^base     ^top
  */
  return 0;
}
#endif

/* Setup call to metamethod to be run by Assembler VM. */
static TValue *mmcall(lua_State *L, ASMFunction cont, cTValue *mo,
		    cTValue *a, cTValue *b)
{
  /*
  **           |-- framesize -> top       top+1       top+2 top+3
  ** before:   [func slots ...]
  ** mm setup: [func slots ...] [cont|?]  [mo|tmtype] [a]   [b]
  ** in asm:   [func slots ...] [cont|PC] [mo|delta]  [a]   [b]
  **           ^-- func base                          ^-- mm base
  ** after mm: [func slots ...]           [result]
  **                ^-- copy to base[PC_RA] --/     for lj_cont_ra
  **                          istruecond + branch   for lj_cont_cond*
  **                                       ignore   for lj_cont_nop
  ** next PC:  [func slots ...]
  */
  TValue *top = L->top;
  if (curr_funcisL(L)) top = curr_topL(L);
  setcont(top++, cont);  /* Assembler VM stores PC in upper word or FR2. */
  if (LJ_FR2) setnilV(top++);
  copyTV(L, top++, mo);  /* Store metamethod and two arguments. */
  if (LJ_FR2) setnilV(top++);
  copyTV(L, top, a);
  copyTV(L, top+1, b);
  return top;  /* Return new base. */
}

/* mmcall() for a metamethod whose name is known at the call site: when the
** metamethod value itself is not callable and has no __call chain, PUC names
** it in the error ("attempt to call a number value (metamethod 'add')",
** luaG_typeerror on the metamethod). Without the chain there is nothing left
** to call, so raise here instead of in the generic call dispatch, which cannot
** name the metamethod. */
static TValue *mmcall_mm(lua_State *L, ASMFunction cont, cTValue *mo,
			 cTValue *a, cTValue *b, const char *mmname)
{
  if (LJ_UNLIKELY(!tvisfunc(mo)) &&
      tvisnil(lj_meta_lookup(L, mo, MM_call)))
    lj_err_msgv(L, LJ_ERR_BADCALLMM, lj_err_typename(L, mo), mmname);
  return mmcall(L, cont, mo, a, b);
}

/* -- C helpers for some instructions, called from assembler VM ----------- */

/* Helper for TGET*. __index chain and metamethod. isenv selects the 5.4
** _ENV error wording ("upvalue '_ENV'") on the no-metamethod path. */
static cTValue *meta_tget(lua_State *L, cTValue *o, cTValue *k, int isenv)
{
  int loop;
  for (loop = 0; loop < LJ_MAX_IDXCHAIN; loop++) {
    cTValue *mo;
    if (LJ_LIKELY(tvistab(o))) {
      GCtab *t = tabV(o);
      cTValue *tv = lj_tab_get(L, t, k);
      if (!tvisnil(tv) ||
	  !(mo = lj_meta_fast(L, tabref(t->metatable), MM_index)))
	return tv;
    } else if (tvisnil(mo = lj_meta_lookup(L, o, MM_index))) {
      if (isenv) lj_err_envtype(L, o);
      lj_err_optype(L, o, LJ_ERR_OPINDEX);
      return NULL;  /* unreachable */
    }
    if (tvisfunc(mo)) {
      L->top = mmcall(L, lj_cont_ra, mo, o, k);
      return NULL;  /* Trigger metamethod call. */
    }
    o = mo;
  }
  lj_err_msg(L, LJ_ERR_GETLOOP);
  return NULL;  /* unreachable */
}

/* Helper for TGET*. __index chain and metamethod. */
cTValue *lj_meta_tget(lua_State *L, cTValue *o, cTValue *k)
{
  return meta_tget(L, o, k, 0);
}

/* 5.4: TGET* on a function's non-table _ENV value. */
cTValue *lj_meta_tget_env(lua_State *L, cTValue *o, cTValue *k)
{
  return meta_tget(L, o, k, 1);
}

/* Helper for TSET*. __newindex chain and metamethod. isenv selects the 5.4
** _ENV error wording ("upvalue '_ENV'") on the no-metamethod path. */
static TValue *meta_tset(lua_State *L, cTValue *o, cTValue *k, int isenv)
{
  TValue tmp;
  int loop;
  for (loop = 0; loop < LJ_MAX_IDXCHAIN; loop++) {
    cTValue *mo;
    if (LJ_LIKELY(tvistab(o))) {
      GCtab *t = tabV(o);
      cTValue *tv = lj_tab_get(L, t, k);
      if (LJ_LIKELY(!tvisnil(tv))) {
	t->nomm = 0;  /* Invalidate negative metamethod cache. */
	lj_gc_anybarriert(L, t);
	return (TValue *)tv;
      } else if (!(mo = lj_meta_fast(L, tabref(t->metatable), MM_newindex))) {
	t->nomm = 0;  /* Invalidate negative metamethod cache. */
	lj_gc_anybarriert(L, t);
	if (tv != niltv(L))
	  return (TValue *)tv;
	if (tvisnil(k)) lj_err_msg(L, LJ_ERR_NILIDX);
	else if (tvisnum(k) && tvisnan(k)) lj_err_msg(L, LJ_ERR_NANIDX);
	/* 5.4 (ADR-001b): integer keys keep their canonical integer encoding
	** and integral floats become integers; lj_tab_set() knows the rules. */
	return lj_tab_set(L, t, k);
      }
    } else if (tvisnil(mo = lj_meta_lookup(L, o, MM_newindex))) {
      if (isenv) lj_err_envtype(L, o);
      lj_err_optype(L, o, LJ_ERR_OPINDEX);
      return NULL;  /* unreachable */
    }
    if (tvisfunc(mo)) {
      L->top = mmcall(L, lj_cont_nop, mo, o, k);
      /* L->top+2 = v filled in by caller. */
      return NULL;  /* Trigger metamethod call. */
    }
    copyTV(L, &tmp, mo);
    o = &tmp;
  }
  lj_err_msg(L, LJ_ERR_SETLOOP);
  return NULL;  /* unreachable */
}

/* Helper for TSET*. __newindex chain and metamethod. */
TValue *lj_meta_tset(lua_State *L, cTValue *o, cTValue *k)
{
  return meta_tset(L, o, k, 0);
}

/* 5.4: TSET* on a function's non-table _ENV value. */
TValue *lj_meta_tset_env(lua_State *L, cTValue *o, cTValue *k)
{
  return meta_tset(L, o, k, 1);
}

/* Float value of a number operand; an integer outside int32 (inline 47 bit
** or boxed) has no number tag, so numberVnum() must not see it. */
static LJ_AINLINE lua_Number num2float(cTValue *o)
{
  int64_t v;
  return lj_i64_getint(o, &v) ? (lua_Number)v : numV(o);
}

static cTValue *str2num(lua_State *L, cTValue *o, TValue *n)
{
  if (tvisnum(o) || tvisint(o) || tvisi64(o))
    return o;  /* Floats and 5.4 integers (inline, widened, boxed) stay as-is. */
  else if (tvisstr(o)) {
#if LJ_DUALNUM
    /* 5.4: integer-syntax strings stay integers, decimal/exponent strings
    ** are floats ("1e2" * 2 is 200.0, "10" + 5 is 15). The scanner makes
    ** that distinction itself; guessing it from the characters took the hex
    ** digit 'e' for an exponent ("0x1e" + 0 was 30.0). */
    if (lj_strscan_number64(L, strV(o), n))
#else
    if (lj_strscan_num(strV(o), n))
#endif
      return n;
    return NULL;
  }
  else
    return NULL;
}

/* ADR-001b: an arithmetic or bitwise result that had to be boxed is the only
** allocation a loop of pure int64 arithmetic makes, and the VM's arithmetic
** fallbacks have no GC check of their own -- so drive the collector here,
** like lj_meta_cat() does. Only the VM calls these helpers (L->top is not
** set up; the VM reloads BASE after the call, the stack may move). */
static LJ_AINLINE void meta_i64_gccheck(lua_State *L, cTValue *ra)
{
  if (tvisi64(ra) && LJ_UNLIKELY(G(L)->gc.total >= G(L)->gc.threshold)) {
    L->top = curr_topL(L);
    lj_gc_step(L);
  }
}

/* The metamethod name without its "__" prefix, for the error wording: PUC's
** luaG_typeerror names the metamethod value ("metamethod 'add'"). */
static const char *mmname(lua_State *L, MMS mm)
{
  return strdata(mmname_str(G(L), mm)) + 2;
}

/* Helper for arithmetic instructions. Coercion, metamethod. */
TValue *lj_meta_arith(lua_State *L, TValue *ra, cTValue *rb, cTValue *rc,
		      BCReg op)
{
  MMS mm = bcmode_mm(op);
  TValue tempb, tempc;
  cTValue *b, *c;
  /* Lua 5.4 exact 64-bit semantics (ADR-001b): a boxed integer operand, or an
  ** int32 overflow that landed here, is handled by the C helper. */
  if (mm == MM_unm) {  /* Unary minus: wraps, -mininteger == mininteger. */
    if (lj_i64_unop(L, ra, rb, I64_UNM)) {
      meta_i64_gccheck(L, ra);
      return NULL;  /* Handled. */
    }
  } else if (mm < MM__MAX) {
    I64Op iop = lj_i64_op_from_mm(mm);
    if (iop != I64__MAX &&
	(tvisi64(rb) || tvisi64(rc) || tvisint(rb) || tvisint(rc) ||
	 tvisnum(rb) || tvisnum(rc))) {
      if (lj_i64_arith(L, ra, rb, rc, iop)) {
	meta_i64_gccheck(L, ra);
	return NULL;  /* Handled. */
      }
    }
  }
  if ((b = str2num(L, rb, &tempb)) != NULL &&
      (c = str2num(L, rc, &tempc)) != NULL) {
    /* Lua 5.4: a coerced string keeps its integer form when both operands
    ** are integers, so "3" + 3 is 3, not 3.0. */
    if (mm < MM__MAX && lj_i64_op_from_mm(mm) != I64__MAX &&
	(tvisint(b) || tvisi64(b)) && (tvisint(c) || tvisi64(c)) &&
	lj_i64_arith(L, ra, b, c, lj_i64_op_from_mm(mm))) {
      meta_i64_gccheck(L, ra);
      return NULL;
    }
    if (mm == MM_unm) {
      /* Unary minus on a coerced string: keep the integer form if the string
      ** was an integer ("-\"10\"" is the integer -10 in 5.4). */
      if (tvisint(b) || tvisi64(b)) {
	if (lj_i64_unop(L, ra, b, I64_UNM)) {
	  meta_i64_gccheck(L, ra);
	  return NULL;
	}
      }
      setnumV(ra, -num2float(b));
      return NULL;
    }
    if (mm == MM_idiv) {  /* no IR op for idiv: floor, as 5.4 does */
      setnumV(ra, lj_vm_floor(num2float(b) / num2float(c)));
      return NULL;
    }
    {
      lua_Number x = num2float(b), y = num2float(c), r;
      switch (mm) {
      case MM_add: r = x + y; break;
      case MM_sub: r = x - y; break;
      case MM_mul: r = x * y; break;
      case MM_div: r = x / y; break;
      case MM_mod: {
	lua_Number m;
	if (y == 0) { r = x / y * 0; break; }  /* nan, as in Lua */
	m = fmod(x, y);
	r = ((m > 0 && y < 0) || (m < 0 && y > 0)) ? m + y : m;
	break;
      }
      case MM_pow: r = lj_vm_foldarith(x, y, (int)MM_pow - (int)MM_add); break;
      case MM_idiv: r = lj_vm_floor(x / y); break;
      default: r = x; break;
      }
      setnumV(ra, r);
    }
    return NULL;
  } else {
    cTValue *mo = lj_meta_lookup(L, rb, mm);
    if (tvisnil(mo)) {
      mo = lj_meta_lookup(L, rc, mm);
      if (tvisnil(mo)) {
	if (mm >= MM_add && mm <= MM_idiv && (tvisstr(rb) || tvisstr(rc))) {
	  lj_err_msgv(L, LJ_ERR_OPBIN54, mmname(L, mm),
		      lj_typename(rb), lj_typename(rc));
	}
	if (str2num(L, rb, &tempb) == NULL) rc = rb;
	lj_err_optype(L, rc, LJ_ERR_OPARITH);
	return NULL;  /* unreachable */
      }
    }
    return mmcall_mm(L, lj_cont_ra, mo, rb, rc,
		     mmname(L, mm));
  }
}

/* Helper for bit operators. Lua 5.4 semantics (ADR-001b): integer operands are
** 64-bit, floats must have an exact integer representation; cdata keeps the
** LuaJIT extension behaviour. */
/* 5.4 bitwise metamethod for a bit operator bytecode (MM__MAX: none). */
static MMS bitop_mm(BCReg op)
{
  switch (op) {
  case BC_BAND: return MM_band;
  case BC_BOR: return MM_bor;
  case BC_BXOR: return MM_bxor;
  case BC_BSHL: return MM_shl;
  case BC_BSHR: return MM_shr;
  case BC_BNOT: return MM_bnot;
  default: return MM__MAX;  /* BSAR/BROL/BROR: LuaJIT-only, no metamethod. */
  }
}

/* Returns NULL when done, or the new base of a metamethod call (like
** lj_meta_arith): 5.4 tries __band/__bor/__bxor/__shl/__shr/__bnot on the
** first, then the second operand (__bnot gets the operand twice). */
TValue *lj_meta_bitop(lua_State *L, TValue *ra, cTValue *rb, cTValue *rc, BCReg op)
{
#if LJ_HASFFI
  if (!(tviscdata(rb) || tviscdata(rc))) {
    int bnum = tvisnumber(rb) || tvisi64(rb), cnum = tvisnumber(rc) || tvisi64(rc);
    /* Two numbers: the integer path, which raises "number has no integer
    ** representation" itself. Otherwise the metamethod comes first (PUC
    ** luaT_trybinTM): 3.5 & obj calls obj's __band. */
    if (bnum && cnum) {
      if (lj_i64_bitop(L, ra, rb, rc, op)) {
	meta_i64_gccheck(L, ra);
	return NULL;
      }
    } else {
      MMS mm = bitop_mm(op);
      if (mm != MM__MAX) {
	cTValue *mo = lj_meta_lookup(L, rb, mm);
	if (tvisnil(mo)) mo = lj_meta_lookup(L, rc, mm);
	if (!tvisnil(mo))
	  return mmcall(L, lj_cont_ra, mo, rb, rc);
      }
    }
    {
      cTValue *o = (tvisint(rb) || tvisi64(rb) || tvisnum(rb)) ? rc : rb;
      const char *tname = lj_err_typename(L, o);
      const char *oname = NULL;
      if (curr_funcisL(L)) {
	GCproto *pt = curr_proto(L);
	const BCIns *pc = cframe_Lpc(L) - 1;
	const char *kind = lj_debug_slotname(pt, pc, (BCReg)(o-L->base), &oname);
	if (kind && oname)
	  lj_err_msgv(L, LJ_ERR_BADOPBITK, tname, kind, oname);
      }
      lj_err_msgv(L, LJ_ERR_BADOPBIT, tname);
    }
  }
  CTypeID id = 0, id_ignore = 0;
  uint64_t b = lj_carith_checkbit64(L, rb, &id);
  uint64_t c = lj_carith_checkbit64(L, rc, op >= BC_BSHL ? &id_ignore : &id);
  if (id) {
    if (tvisnum(rb)) {
      b = id == CTID_UINT64 ? lj_num2u64(numV(rb)) : (uint64_t)lj_num2i64(numV(rb));
    }
    if (tvisnum(rc)) {
      c = id == CTID_UINT64 ? lj_num2u64(numV(rc)) : (uint64_t)lj_num2i64(numV(rc));
    }
  }
  switch (op) {
  case BC_BNOT: b = ~b; break;
  case BC_BAND: b &= c; break;
  case BC_BOR: b |= c; break;
  case BC_BXOR: b ^= c; break;
  default:
    if (id) {
      b = lj_carith_shift64(b, (int32_t)c, op-BC_BSHL);
    } else if (op == BC_BSHL) {
      b = (uint64_t)((uint32_t)b << ((uint32_t)c & 31));
    } else if (op == BC_BSHR) {
      b = (uint64_t)((uint32_t)b >> ((uint32_t)c & 31));
    } else {
      lj_assertL(op == BC_BSAR, "bad bytecode op %d", op);
      b = (uint64_t)(uint32_t)((int32_t)b >> ((uint32_t)c & 31));
    }
    break;
  }
  if (id) {
    GCcdata *cd = lj_cdata_new_(L, id, 8);
    *(uint64_t *)cdataptr(cd) = b;
    setcdataV(L, ra, cd);
  } else {
    setintV(ra, (int32_t)b);
  }
  return NULL;
#else
#if LJ_DUALNUM
  uint32_t b = 0, c = 0;
  if (tvisint(rb)) b = (uint32_t)intV(rb);
  else if (tvisnum(rb)) b = (uint32_t)lj_num2bit(numV(rb));
  else goto err;
  if (tvisint(rc)) c = (uint32_t)intV(rc);
  else if (tvisnum(rc)) c = (uint32_t)lj_num2bit(numV(rc));
  else goto err;
  switch (op) {
  case BC_BNOT: b = ~b; break;
  case BC_BAND: b &= c; break;
  case BC_BOR: b |= c; break;
  case BC_BXOR: b ^= c; break;
  case BC_BSHL: b <<= (c & 31); break;
  case BC_BSHR: b >>= (c & 31); break;
  case BC_BSAR: b = (uint32_t)((int32_t)b >> (c & 31)); break;
  default:
    lj_assertL(0, "bad bytecode op %d", op);
    break;
  }
  setintV(ra, (int32_t)b);
  return NULL;
err:
#endif
  UNUSED(ra); UNUSED(op);
  lj_err_optype(L, tvisnumber(rb) ? rc : rb, LJ_ERR_OPARITH);
#endif
}

/* Helper for CAT. Coercion, iterative concat, __concat metamethod. */
TValue *lj_meta_cat(lua_State *L, TValue *top, int left)
{
  int fromc = 0;
  TValue *ftop = top;  /* Last operand: BC_CAT's operands end at the free register. */
  if (left < 0) { left = -left; fromc = 1; }
  do {
    if (!(tvisstr(top) || tvisnumber(top) || tvisi64(top) || tvisbuf(top)) ||
	!(tvisstr(top-1) || tvisnumber(top-1) || tvisi64(top-1) ||
	  tvisbuf(top-1))) {
      cTValue *mo = lj_meta_lookup(L, top-1, MM_concat);
      if (tvisnil(mo)) {
	mo = lj_meta_lookup(L, top, MM_concat);
	if (tvisnil(mo)) {
	  if (tvisstr(top-1) || tvisnumber(top-1) || tvisi64(top-1)) top++;
	  lj_err_optype(L, top-1, LJ_ERR_OPCAT);
	  return NULL;  /* unreachable */
	}
      }
      /* One of the top two elements is not a string, call __cat metamethod:
      **
      ** before:    [...][CAT stack .........................]
      **                                 top-1     top         top+1 top+2
      ** pick two:  [...][CAT stack ...] [o1]      [o2]
      ** setup mm:  [...][CAT stack ...] [cont|?]  [mo|tmtype] [o1]  [o2]
      ** in asm:    [...][CAT stack ...] [cont|PC] [mo|delta]  [o1]  [o2]
      **            ^-- func base                              ^-- mm base
      ** after mm:  [...][CAT stack ...] <--push-- [result]
      ** next step: [...][CAT stack .............]
      */
      copyTV(L, top+2*LJ_FR2+2, top);  /* Carefully ordered stack copies! */
      copyTV(L, top+2*LJ_FR2+1, top-1);
      copyTV(L, top+LJ_FR2, mo);
      setcont(top-1, lj_cont_cat);
      if (LJ_FR2) { setnilV(top); setnilV(top+2); top += 2; }
      return top+1;  /* Trigger metamethod call. */
    } else {
      /* Pick as many strings as possible from the top and concatenate them:
      **
      ** before:    [...][CAT stack ...........................]
      ** pick str:  [...][CAT stack ...] [...... strings ......]
      ** concat:    [...][CAT stack ...] [result]
      ** next step: [...][CAT stack ............]
      */
      TValue *e, *o = top;
      uint64_t tlen = tvisstr(o) ? strV(o)->len :
		      tvisbuf(o) ? sbufxlen(bufV(o)) : STRFMT_MAXBUF_NUM;
      SBuf *sb;
      do {
	o--; tlen += tvisstr(o) ? strV(o)->len :
		     tvisbuf(o) ? sbufxlen(bufV(o)) : STRFMT_MAXBUF_NUM;
      } while (--left > 0 && (tvisstr(o-1) || tvisnumber(o-1) || tvisi64(o-1)));
      if (tlen >= LJ_MAX_STR) lj_err_msg(L, LJ_ERR_STROV);
      sb = lj_buf_tmp_(L);
      lj_buf_more(sb, (MSize)tlen);
      for (e = top, top = o; o <= e; o++) {
	if (tvisstr(o)) {
	  GCstr *s = strV(o);
	  MSize len = s->len;
	  lj_buf_putmem(sb, strdata(s), len);
	} else if (tvisbuf(o)) {
	  SBufExt *sbx = bufV(o);
	  lj_buf_putmem(sb, sbx->r, sbufxlen(sbx));
	} else if (tvisint(o)) {
	  if (tvisi47w(o)) lj_strfmt_putfxint(sb, STRFMT_D, (uint64_t)intV47(o));
	  else lj_strfmt_putint(sb, intV(o));
	} else if (tvisi64(o)) {  /* Boxed 5.4 integer (ADR-001b). */
	  lj_strfmt_putfxint(sb, STRFMT_D, (uint64_t)i64V(o));
	} else {
	  lj_strfmt_putfnumstr(sb, numV(o));
	}
      }
      setstrV(L, top, lj_buf_str(L, sb));
    }
  } while (left >= 1);
  if (LJ_UNLIKELY(G(L)->gc.total >= G(L)->gc.threshold)) {
    if (!fromc) L->top = ftop + 1;  /* PUC's checkGC(L, one past the operands). */
    lj_gc_step(L);
  }
  return NULL;
}

/* Helper for LEN. __len metamethod. */
TValue * LJ_FASTCALL lj_meta_len(lua_State *L, cTValue *o)
{
  cTValue *mo = lj_meta_lookup(L, o, MM_len);
  if (tvisnil(mo)) {
    if (tvistab(o))
      tabref(tabV(o)->metatable)->nomm |= (uint8_t)(1u<<MM_len);
    else
      lj_err_optype(L, o, LJ_ERR_OPLEN);
    return NULL;
  }
  /* 5.4: __len may return any value, and applies to tables too. */
  return mmcall(L, lj_cont_ra, mo, o, o);
}

/* Helper for equality comparisons. __eq metamethod. */
TValue *lj_meta_equal(lua_State *L, GCobj *o1, GCobj *o2, int ne)
{
  /* 5.4 (lobject.c luaV_equalobj): the __eq handler of the first operand is
  ** used; only if it has none, the second one's. The call keeps the source
  ** order. LuaJIT used the 5.1 rule instead: both operands had to carry the
  ** same __eq, so `set == plain` never called the metamethod.
  ** Field metatable must be at same offset for GCtab and GCudata! */
  GCtab *mt1 = tabref(o1->gch.metatable), *mt2 = tabref(o2->gch.metatable);
  cTValue *mo = lj_meta_fast(L, mt1, MM_eq);
  if (mo == NULL && mt1 != mt2)
    mo = lj_meta_fast(L, mt2, MM_eq);
  if (mo) {
    TValue *top;
    uint32_t it;
    top = curr_top(L);
    setcont(top++, ne ? lj_cont_condf : lj_cont_condt);
    if (LJ_FR2) setnilV(top++);
    copyTV(L, top++, mo);
    if (LJ_FR2) setnilV(top++);
    it = ~(uint32_t)o1->gch.gct;
    setgcV(L, top, o1, it);
    setgcV(L, top+1, o2, it);
    return top;  /* Trigger metamethod call. */
  }
  return (TValue *)(intptr_t)ne;
}

/* Exact 5.4 equality for the VM's slow path (ADR-001b): either operand may be
** a widened 47-bit inline integer or an interned int64 box, which compare by
** value against any number. Same return convention as lj_meta_equal: 0/1 is
** the branch decision, a TValue * requests the __eq metamethod call. The raw
** TValue words are passed so the VM need not re-derive slot pointers. */
TValue *lj_meta_equal_any(lua_State *L, uint64_t a, uint64_t b, int ne)
{
  TValue ta, tb;
  ta.u64 = a; tb.u64 = b;
  if (a == b) return (TValue *)(intptr_t)(1 ^ ne);
  if (itype(&ta) == itype(&tb) && (tvistab(&ta) || tvisudata(&ta)) &&
      !tvisi64(&ta) && !tvisi64(&tb))
    return lj_meta_equal(L, gcV(&ta), gcV(&tb), ne);
  return (TValue *)(intptr_t)(lj_obj_equal(&ta, &tb) ^ ne);
}

#if LJ_HASFFI
TValue * LJ_FASTCALL lj_meta_equal_cd(lua_State *L, BCIns ins)
{
  ASMFunction cont = (bc_op(ins) & 1) ? lj_cont_condf : lj_cont_condt;
  int op = (int)bc_op(ins) & ~1;
  TValue tv;
  cTValue *mo, *o2, *o1 = &L->base[bc_a(ins)];
  cTValue *o1mm = o1;
  if (op == BC_ISEQV) {
    o2 = &L->base[bc_d(ins)];
    if (!tviscdata(o1mm)) o1mm = o2;
  } else if (op == BC_ISEQS) {
    setstrV(L, &tv, gco2str(proto_kgc(curr_proto(L), ~(ptrdiff_t)bc_d(ins))));
    o2 = &tv;
  } else if (op == BC_ISEQN) {
    o2 = &mref(curr_proto(L)->k, cTValue)[bc_d(ins)];
  } else {
    lj_assertL(op == BC_ISEQP, "bad bytecode op %d", op);
    setpriV(&tv, ~bc_d(ins));
    o2 = &tv;
  }
  mo = lj_meta_lookup(L, o1mm, MM_eq);
  if (LJ_LIKELY(!tvisnil(mo)))
    return mmcall(L, cont, mo, o1, o2);
  else
    return (TValue *)(intptr_t)(bc_op(ins) & 1);
}
#endif

/* Helper for ordered comparisons. String compare, __lt/__le metamethods. */
TValue *lj_meta_comp(lua_State *L, cTValue *o1, cTValue *o2, int op)
{
  /* ADR-001b: comparisons involving a boxed int64 are numeric comparisons
  ** (5.4: int/float comparison is exact), never metamethod dispatch. */
  if (tvisi64(o1) || tvisi64(o2) ||
#if LJ_GC64
      tvisi47w(o1) || tvisi47w(o2) ||
#endif
      0) {
    int res;
    if (lj_i64_compare(o1, o2, op & 2 ? 2 : 1, &res))
      return (TValue *)(intptr_t)(res ^ (op & 1));
  }
  if (LJ_HASFFI && (tviscdata(o1) || tviscdata(o2))) {
    ASMFunction cont = (op & 1) ? lj_cont_condf : lj_cont_condt;
    MMS mm = (op & 2) ? MM_le : MM_lt;
    cTValue *mo = lj_meta_lookup(L, tviscdata(o1) ? o1 : o2, mm);
    if (LJ_UNLIKELY(tvisnil(mo))) goto err;
    return mmcall(L, cont, mo, o1, o2);
  } else if (LJ_52 || itype(o1) == itype(o2)) {
    /* Never called with two numbers. */
    if (tvisstr(o1) && tvisstr(o2)) {
      int32_t res = lj_str_cmp(strV(o1), strV(o2));
      return (TValue *)(intptr_t)(((op&2) ? res <= 0 : res < 0) ^ (op&1));
    } else {
    trymt:
      while (1) {
	ASMFunction cont = (op & 1) ? lj_cont_condf : lj_cont_condt;
	MMS mm = (op & 2) ? MM_le : MM_lt;
	cTValue *mo = lj_meta_lookup(L, o1, mm);
#if LJ_52
	if (tvisnil(mo) && tvisnil((mo = lj_meta_lookup(L, o2, mm))))
#else
	cTValue *mo2 = lj_meta_lookup(L, o2, mm);
	if (tvisnil(mo) || !lj_obj_equal(mo, mo2))
#endif
	{
	  if (op & 2) {  /* MM_le not found: retry with MM_lt. */
	    cTValue *ot = o1; o1 = o2; o2 = ot;  /* Swap operands. */
	    op ^= 3;  /* Use LT and flip condition. */
	    continue;
	  }
	  goto err;
	}
	return mmcall_mm(L, cont, mo, o1, o2, mmname(L, mm));
      }
    }
  } else if (tvisbool(o1) && tvisbool(o2)) {
    goto trymt;
  } else {
  err:
    lj_err_comp(L, o1, o2);
    return NULL;
  }
}

/* Helper for ISTYPE and ISNUM. Implicit coercion or error. */
void lj_meta_istype(lua_State *L, BCReg ra, BCReg tp)
{
  L->top = curr_topL(L);
  ra++; tp--;
  lj_assertL(LJ_DUALNUM || tp != ~LJ_TNUMX, "bad type for ISTYPE");
  if (LJ_DUALNUM && tp == ~LJ_TNUMX) lj_lib_checkint(L, ra);
  else if (tp == ~LJ_TNUMX+1) lj_lib_checknum(L, ra);
  else if (tp == ~LJ_TSTR) lj_lib_checkstr(L, ra);
  else lj_err_argtype(L, ra, lj_obj_itypename[tp]);
}

#if LJ_META_CALLCHAIN
/* A stack overflow raised while resolving a call has no target frame yet. If
** the caller is a fast pcall/xpcall (its C-frame pc is not a Lua frame), put
** the same dummy frame in the func slot that lj_err_optype_call installs for
** a non-callable target, so the overflow unwinds into the protected call
** instead of escaping it. The VM's pcall path depends on this frame shape.
*/
static void stkov_callframe(lua_State *L, TValue *func)
{
  const BCIns *pc = cframe_Lpc(L);
  if (((ptrdiff_t)pc & FRAME_TYPE) != FRAME_LUA) {
    setframe_gc(func, obj2gco(L), LJ_TTHREAD);
    if (LJ_FR2) func++;
    setframe_pc(func, pc);
    L->top = L->base = func+1;
  }
}

/* Helper for calls. __call metamethod chain (PUC 5.4 luaD_tryfuncTM retry).
** Every callable object on the chain is prepended as an argument, innermost
** first, and the func slot finally holds the first plain function. The chain
** is bounded by the Lua stack, like PUC: the per-level stack request grows the
** stack and a cyclic or over-long chain raises the usual "stack overflow"
** instead of a fixed depth limit. The stack may move while growing, so the
** caller gets the (possibly moved) func slot back and rebases its own
** addresses; the number of prepended objects is reported through metanargs.
** The prepends are done in one linear shift here, unlike PUC's per-level
** shift, which is quadratic.
*/
TValue *lj_meta_call(lua_State *L, TValue *func, TValue *top)
{
  TValue cur;
  ptrdiff_t fofs = savestack(L, func);
  ptrdiff_t tofs = savestack(L, top);
  MSize n = 0;
  copyTV(L, &cur, func);  /* Walk the chain without touching the stack. */
  for (;;) {
    cTValue *mo = lj_meta_lookup(L, &cur, MM_call);
    if (tvisnil(mo)) {  /* A non-callable object named at its level. */
      func = restorestack(L, fofs);
      copyTV(L, func, &cur);  /* Put it in the func slot for the error name. */
      lj_err_optype_call(L, func);
    }
    n++;
    func = restorestack(L, fofs);
    top = restorestack(L, tofs);
    /* Room for n more slots above the call's arguments. L->top is no
    ** measure for it: it is where the last C call left it, which can be far
    ** below this call (the request would then be for that whole distance and
    ** overflow early) or above it. */
    if ((mref(L->maxstack, char) - (char *)top) <=
	(ptrdiff_t)n*(ptrdiff_t)sizeof(TValue)) {
      /* Same test as in lj_state_growstack: the request cannot be met. */
      if (L->stacksize + n >= LUAI_MAXSTACK)
	stkov_callframe(L, func);  /* Make the overflow catchable by pcall. */
      lj_state_growstack(L, n);  /* May move the stack or raise the error. */
    }
    if (tvisfunc(mo)) break;
    copyTV(L, &cur, mo);
  }
  func = restorestack(L, fofs);
  top = restorestack(L, tofs);
  {
    TValue *p;
    ptrdiff_t i;
    for (p = top; p > func+1+LJ_FR2; p--)  /* Shift the arguments up by n. */
      copyTV(L, p+n-1, p-1);
    copyTV(L, &cur, func);
    for (i = 0; i < (ptrdiff_t)n; i++) {
      cTValue *mo = lj_meta_lookup(L, &cur, MM_call);
      /* Innermost object first, the called object last. */
      copyTV(L, func+1+LJ_FR2+(n-1-i), &cur);
      if (tvisnil(mo)) {
	copyTV(L, func, &cur);
	lj_err_optype_call(L, func);
      }
      if (tvisfunc(mo)) {
	copyTV(L, func, mo);
	break;
      }
      copyTV(L, &cur, mo);
    }
  }
  L->metanargs = n;  /* The VM adds this to its nargs bookkeeping. */
  return func;
}
#else
/* Helper for calls. __call metamethod, one level: the interpreters that are
** not ported to the chain neither rebase after this call nor read metanargs,
** so the stack must not move here and exactly one argument is added. */
TValue *lj_meta_call(lua_State *L, TValue *func, TValue *top)
{
  cTValue *mo = lj_meta_lookup(L, func, MM_call);
  TValue *p;
  if (!tvisfunc(mo))
    lj_err_optype_call(L, func);
  for (p = top; p > func+2*LJ_FR2; p--) copyTV(L, p, p-1);
  if (LJ_FR2) copyTV(L, func+2, func);
  copyTV(L, func, mo);
  L->metanargs = 1;
  return func;
}
#endif

/* -- Lua 5.4 numeric 'for' loops ----------------------------------------- */

/* Specification: PUC 5.4.9 lvm.c forprep/forlimit and OP_FORLOOP. The loop is
** an integer loop iff the initial value and the step are integers (no string
** coercion for those two). Then the limit is converted with floor for an
** ascending and ceil for a descending loop, clipped to the integer bounds or
** skipping the loop; the index wraps like intop(+), so the integer limits
** cannot make a loop run forever. Otherwise all three values are converted
** with tonumber. Step zero raises for both kinds. Three loop kinds after
** FORI: small integer (init, step and clipped limit fit int32, the existing
** int32 FORI/FORL paths are exact for it), float, and wide integer (any of
** the three outside int32).
**
** A wide loop keeps plain numbers in its slots, as PUC does: the index in
** FOR_IDX, the clipped limit in FOR_STOP and the step in FOR_STEP, all in
** their canonical 5.4 integer encoding, and the control variable in FOR_EXT.
** The one exception is an index that fits int32 while the limit or the step
** does not: FOR_IDX then holds it as a float (exact), because the int32 FORL
** path takes FOR_IDX as the only witness and reads the other two slots by
** their low words. A wide loop's step is an integer, which sends the FP path
** of FORL/IFORL/JFORL to lj_meta_forl once per iteration. Nothing in the
** slots is a pointer the VM follows, so values written there through the
** debug library cannot corrupt anything: lj_meta_forl takes the slots as
** they are (see there). FORL takes the body address from its own
** instruction (a JFORL's from the trace's start instruction). */

static int for_isint(cTValue *o)
{
  return tvisint(o) || tvisi64(o);  /* int32, 47-bit inline, or boxed */
}

#define for_fits32(v)	((int64_t)(int32_t)(v) == (v))

/* lj_i64_getint, inline for the per-iteration path of a wide loop. */
static LJ_AINLINE int for_getint(cTValue *o, int64_t *p)
{
#if LJ_GC64
  if (tvisi47w(o)) { *p = intV47(o); return 1; }
#endif
  if (tvisint(o)) { *p = (int64_t)intV(o); return 1; }
  if (tvisi64(o)) { *p = i64V(o); return 1; }
  return 0;
}

/* PUC luaV_flttointeger: floor for an ascending loop, ceil for a descending
** one (only F2Ieq rejects a non-integral float), then the range check. */
static int for_flttoint(lua_Number n, int64_t *p, int ceil)
{
  lua_Number f = floor(n);
  if (n != f && ceil) f += 1;
  /* MININTEGER has an exact float form, MAXINTEGER may round up to 2^63. */
  if (!(f >= -9223372036854775808.0 && f < 9223372036854775808.0)) return 0;
  *p = (int64_t)f;
  return 1;
}

static int for_toint(cTValue *o, int64_t *p, int ceil)
{
  int64_t i;
  if (lj_i64_getint(o, &i)) { *p = i; return 1; }
  if (tvisnum(o)) return for_flttoint(numV(o), p, ceil);
  return 0;
}

/* PUC luaV_tointeger: a numeric string is converted first. The scanner uses
** the 5.4 rules (hex wraps mod 2^64, a decimal integer that does not fit
** int64 becomes a float), so the results match luaO_str2num. */
static int for_tointeger(lua_State *L, cTValue *o, int64_t *p, int ceil)
{
  if (tvisstr(o)) {
    TValue tv;
    int64_t i;
    setnilV(&tv);  /* the scanner leaves the tag alone for a float result */
    if (!lj_strscan_number64(L, strV(o), &tv)) return 0;
    if (lj_i64_getint(&tv, &i)) { *p = i; return 1; }
    return for_flttoint(numV(&tv), p, ceil);
  }
  return for_toint(o, p, ceil);
}

/* PUC luaV_tonumber_ (integers become exactly-representable floats) plus the
** string coercion of tonumber(). */
static int for_tonumber(lua_State *L, cTValue *o, lua_Number *n)
{
  int64_t i;
  if (lj_i64_getint(o, &i)) { *n = (lua_Number)i; return 1; }
  if (tvisnum(o)) { *n = numV(o); return 1; }
  if (tvisstr(o)) {
    TValue tv;
    setnilV(&tv);
    if (!lj_strscan_number64(L, strV(o), &tv)) return 0;
    if (lj_i64_getint(&tv, &i)) *n = (lua_Number)i;
    else *n = numV(&tv);
    return 1;
  }
  return 0;
}

/* PUC luaG_forerror: "bad 'for' <what> (number expected, got <type>)". */
static void for_errnum(lua_State *L, cTValue *o, const char *what)
{
  lj_err_msgv(L, LJ_ERR_FORBAD, what, lj_err_typename(L, o));
}

/* PUC forlimit: convert the limit, clip a float outside the integer range to
** the nearer bound, or signal a skip when it lies on the wrong side. Returns
** non-zero if the loop must not run. */
static int forlimit(lua_State *L, int64_t init, cTValue *lim, int64_t *limit,
		    int64_t step)
{
  int64_t l;
  if (for_tointeger(L, lim, &l, step < 0)) {
    *limit = l;
  } else {
    lua_Number flim;  /* try as a float: out of the integer range? */
    if (!for_tonumber(L, lim, &flim)) for_errnum(L, lim, "limit");
    if (0 < flim) {	/* positive: too large for maxinteger */
      if (step < 0) return 1;
      *limit = (int64_t)0x7fffffffffffffffLL;
    } else {	/* NaN or less than mininteger */
      if (step > 0) return 1;
      *limit = (int64_t)(-0x7fffffffffffffffLL - 1);
    }
  }
  return step > 0 ? init > *limit : init < *limit;
}

/* Store the index of an integer loop that lj_meta_for or lj_meta_forl runs:
** FOR_EXT gets the canonical integer (it may box), FOR_IDX the same value,
** except an int32 index of a loop whose limit or step is not int32 (small is
** zero): a float there keeps the int32 FORL path away. */
static void for_setidx(lua_State *L, TValue *o, int64_t idx, int small)
{
  if (for_fits32(idx)) {
    setintV(o + FORL_EXT, (int32_t)idx);
    if (small)
      setintV(o, (int32_t)idx);
    else
      setnumV(o, (lua_Number)idx);
  } else {
    ptrdiff_t ofs = savestack(L, o);
    lj_i64_toTValue(L, o + FORL_EXT, idx);  /* Stores base-relative. */
    o = restorestack(L, ofs);
    copyTV(L, o, o + FORL_EXT);
  }
}

int LJ_FASTCALL lj_meta_for(lua_State *L, TValue *o)
{
  int64_t init, step;
  if (for_isint(o) && for_isint(o+2) && for_toint(o, &init, 0) &&
      for_toint(o+2, &step, 0)) {
    int64_t limit;
    if (step == 0) lj_err_msg(L, LJ_ERR_FORZERO);
    if (forlimit(L, init, o+1, &limit, step)) return LJ_FOR_SKIP;
    if (for_fits32(init) && for_fits32(step) && for_fits32(limit)) {
      /* Small integer loop: the int32 FORI/FORL paths are exact (an int32
      ** overflow of idx + step leaves before the wrapped index compares). */
      setintV(o, (int32_t)init);
      setintV(o+1, (int32_t)limit);
      setintV(o+2, (int32_t)step);
      return LJ_FOR_RETRY;
    } else {
      /* Wide integer loop: the step slot already holds the canonical step.
      ** Boxing may allocate: pay for it like any allocation of the VM, with
      ** the frame's slots below the top (lj_gc_check_fixtop). */
      ptrdiff_t ofs = savestack(L, o);
      lj_i64_toTValue(L, o+1, limit);
      for_setidx(L, restorestack(L, ofs), init, 0);
      lj_gc_check_fixtop(L);
      return LJ_FOR_WIDE;
    }
  }
  {
    lua_Number init, limit, step;
    /* PUC's error order for a float loop: limit, step, initial value. */
    if (!for_tonumber(L, o+1, &limit)) for_errnum(L, o+1, "limit");
    if (!for_tonumber(L, o+2, &step)) for_errnum(L, o+2, "step");
    if (!for_tonumber(L, o, &init)) for_errnum(L, o, "initial value");
    if (step == 0) lj_err_msg(L, LJ_ERR_FORZERO);
    if ((0 < step) ? (limit < init) : (init < limit)) return LJ_FOR_SKIP;
    setnumV(o, init);
    setnumV(o+1, limit);
    setnumV(o+2, step);
    return LJ_FOR_RETRY;
  }
}

/* The trace recorder's view of a FORI that has not executed yet: what
** lj_meta_for would leave in the slots, without raising, writing the slots
** or deciding the skip. LJ_FOR_RETRY with out[] holding the int32 values of
** a small integer loop or the floats of a float loop (entered or skipped:
** the recorder decides from them), LJ_FOR_WIDE for everything the recorder
** leaves to the interpreter: a wide loop, a limit outside the integer range,
** step zero, a value that is no number. */
int lj_meta_forkind(lua_State *L, cTValue *o, TValue *out)
{
  int64_t init, step, limit;
  if (for_isint(o) && for_isint(o+2) && for_toint(o, &init, 0) &&
      for_toint(o+2, &step, 0)) {
    if (step == 0 || !for_tointeger(L, o+1, &limit, step < 0) ||
	!(for_fits32(init) && for_fits32(step) && for_fits32(limit)))
      return LJ_FOR_WIDE;
    setintV(out, (int32_t)init);
    setintV(out+1, (int32_t)limit);
    setintV(out+2, (int32_t)step);
    return LJ_FOR_RETRY;
  } else {
    lua_Number ninit, nlimit, nstep;
    if (!for_tonumber(L, o+1, &nlimit) || !for_tonumber(L, o+2, &nstep) ||
	!for_tonumber(L, o, &ninit) || nstep == 0)
      return LJ_FOR_WIDE;
    setnumV(out, ninit);
    setnumV(out+1, nlimit);
    setnumV(out+2, nstep);
    return LJ_FOR_RETRY;
  }
}

/* One iteration of an integer loop that is not small: PUC OP_FORLOOP's
** integer branch. FORL comes here from its FP path whenever the step slot
** does not hold a float, i.e. for a wide loop, and for a loop whose slots
** were rewritten through the debug library. The slots are taken as they are
** now, like PUC reads them: the step must be an integer (not zero), the index
** an integer or a float with an exact integer value, the limit is converted
** like forprep converts it. Anything else is a clean error; no value in the
** slots is followed as a pointer. There is a next value iff index + step does
** not pass the limit (computed without overflow), the same iterations as
** PUC's precomputed count. The control variable gets the canonical encoding;
** when index, limit and step all fit int32 again, the slots go back to the
** int32 form and the int32 FORL path takes over. Returns the PC of the loop
** body to continue, or NULL to leave. */
const BCIns * LJ_FASTCALL lj_meta_forl(lua_State *L, TValue *o)
{
  const BCIns *pc = cframe_pc(cframe_raw(L->cframe));  /* After the FORL. */
  BCIns ins = pc[-1];
  int64_t idx, limit, step;
  int stop;
  ptrdiff_t ofs = savestack(L, o);
#if LJ_HASJIT
  if (bc_op(ins) == BC_JFORL)  /* Its jump field holds the trace number. */
    ins = traceref(L2J(L), bc_d(ins))->startins;
#endif
  lj_assertL(bc_op(ins) == BC_FORL || bc_op(ins) == BC_IFORL,
	     "bad FORL instruction %d", bc_op(ins));
  if (!for_getint(o+2, &step)) for_errnum(L, o+2, "step");
  if (step == 0) lj_err_msg(L, LJ_ERR_FORZERO);
  if (tvisnum(o)) {  /* An int32 index of a wide loop, see for_setidx. */
    if (!lj_i64_numtoint(numV(o), &idx)) lj_err_msg(L, LJ_ERR_NUMNOINT);
  } else if (!for_getint(o, &idx)) {
    for_errnum(L, o, "initial value");
  }
  if (!for_getint(o+1, &limit)) {
    if (forlimit(L, idx, o+1, &limit, step)) return NULL;
    lj_i64_toTValue(L, o+1, limit);  /* Keep the converted limit. */
    o = restorestack(L, ofs);
  }
  if (step > 0)
    stop = idx > limit || (uint64_t)limit - (uint64_t)idx < (uint64_t)step;
  else
    stop = idx < limit ||
	   (uint64_t)idx - (uint64_t)limit < (uint64_t)0 - (uint64_t)step;
  if (stop) return NULL;
  idx = (int64_t)((uint64_t)idx + (uint64_t)step);
  for_setidx(L, o, idx, for_fits32(idx) && for_fits32(limit) &&
			for_fits32(step));
  lj_gc_check_fixtop(L);  /* The control variable may be a new box. */
  return pc + bc_j(ins);
}


/* -- Lua 5.4 to-be-closed variables ------------------------------------- */

/* The pending slots of a thread are kept as stack offsets (innermost last).
** BC_TBC registers a slot at its declaration, BC_UCLO closes the registered
** slots at or above its level in reverse order (one __close call per UCLO
** execution: the lj_cont_tbc continuation restores MULTRES, which the __close
** call clobbers (return f() in a <close> scope is RETM), and re-executes the
** UCLO), coroutine.close
** and the error path close the rest from C. */

static void tbc_push(lua_State *L, TValue *o)
{
  int32_t *list = mref(L->tbclist, int32_t);
  if (LJ_UNLIKELY(L->tbcn >= L->tbcsize)) {
    MSize nsz = L->tbcsize ? L->tbcsize * 2 : 8;
    list = (int32_t *)lj_mem_realloc(L, list, L->tbcsize * sizeof(int32_t),
				     nsz * sizeof(int32_t));
    setmref(L->tbclist, list);
    L->tbcsize = nsz;
  }
  list[L->tbcn++] = (int32_t)savestack(L, o);
}

void lj_meta_tbcfree(global_State *g, lua_State *L)
{
  if (L->tbcsize) {
    lj_mem_free(g, mref(L->tbclist, void), L->tbcsize * sizeof(int32_t));
    setmref(L->tbclist, NULL);
    L->tbcn = L->tbcsize = 0;
  }
}

/* BC_TBC: a to-be-closed variable got its value. nil and false are ignored;
** anything else needs a __close metamethod. */
void LJ_FASTCALL lj_meta_tbcmark(lua_State *L, TValue *o)
{
  if (tvisnil(o) || tvisfalse(o)) return;
  if (tvisnil(lj_meta_lookup(L, o, MM_close))) {
    const char *name = NULL;
    /* No current Lua frame (or no C frame at all, e.g. lua_toclose called
    ** outside a call): report the value without a variable name. */
    if (L->cframe != NULL && curr_funcisL(L)) {
      const BCIns *pc = cframe_pc(cframe_raw(L->cframe));
      lj_debug_slotname(curr_proto(L), pc, (BCReg)(o - L->base), &name);
    }
    lj_err_msgv(L, LJ_ERR_TBCVAL, name ? name : "?");
  }
  tbc_push(L, o);
}

/* BC_UCLO: set up the next __close(value, nil) call for a pending slot at or
** above level, or return NULL when none is left. The VM makes the call with
** the lj_cont_nop continuation returning to the UCLO itself. */
TValue *lj_meta_tbcclose(lua_State *L, TValue *level, MSize multres)
{
  ptrdiff_t lofs = savestack(L, level);
  /* MULTRES is live only when this close sits between the producer of open
  ** results and RETM (return f() in a <close> scope: the jump target of the
  ** UCLO is the RETM). At any other block exit the VM hands over whatever
  ** its MULTRES slot holds. On x64 that slot is shared with a temporary and
  ** can hold half a pointer: the call frame would be placed far outside the
  ** stack. The VM stored the pc behind the UCLO before calling. */
  {
    const BCIns *pc = cframe_Lpc(L);
    if (bc_op(pc[bc_j(pc[-1])]) != BC_RETM)
      multres = 0;
  }
  while (L->tbcn > 0) {
    int32_t *list = mref(L->tbclist, int32_t);
    TValue *o = restorestack(L, list[L->tbcn-1]);
    cTValue *mo;
    TValue *top;
    if (o < restorestack(L, lofs)) return NULL;
    L->tbcn--;
    mo = lj_meta_lookup(L, o, MM_close);
    if (tvisnil(mo))
      lj_err_msgv(L, LJ_ERR_TBCCALL, lj_typename(mo));
    /* Like mmcall(), with one extra slot below the continuation where the
    ** VM parks MULTRES across the call (return f() in a <close> scope is
    ** CALLM + UCLO + RETM). The open results of that CALLM may extend past
    ** the frame size: place the call frame above them. */
    top = curr_topL(L) + (multres >> 3);
    if (top + 8 > tvref(L->maxstack)) {  /* Grow; the VM reloads BASE. */
      ptrdiff_t tofs = savestack(L, L->top);
      L->top = top;  /* lj_state_growstack sizes relative to top. */
      lj_state_growstack(L, 8 + LUA_MINSTACK);
      L->top = restorestack(L, tofs);
      o = restorestack(L, list[L->tbcn]);
      top = curr_topL(L) + (multres >> 3);
    }
    setintV(top, 0);
    setcont(top+1, lj_cont_tbc);
    setnilV(top+2);
    copyTV(L, top+3, mo);
    setnilV(top+4);
    copyTV(L, top+5, o);
    setnilV(top+6);
    return top+5;  /* Trigger metamethod call. */
  }
  return NULL;
}

/* Close all pending slots at or above level from C, each in a protected
** call: __close(value, err). An error inside a __close replaces err (5.4).
** Returns 0 when every call succeeded, otherwise the error status; err then
** holds the new error object. */
int lj_meta_tbccloseall(lua_State *L, TValue *level, TValue *err)
{
  return lj_meta_tbccloseall_at(L, level, err, L->ccallnest,
				G(L)->ccallslack);
}

/* The same with the C-call nesting the handlers are called from given by the
** caller: an unwinding calls them from the nesting of the catching frame,
** which L->ccallnest only reaches when the unwinding is done. slack is the
** number of levels the C stack is deeper than that (see tbc_closeunwound in
** lj_err.c). L->ccallnest is only changed around each handler call, so an
** error raised by this function itself leaves the count alone. */
int lj_meta_tbccloseall_at(lua_State *L, TValue *level, TValue *err,
			   MSize nest, MSize slack)
{
  /* level and err may point into the Lua stack, which the calls below can
  ** reallocate: keep them as offsets. */
  global_State *g = G(L);
  ptrdiff_t lofs = savestack(L, level);
  int errinstack = (err >= tvref(L->stack) && err < tvref(L->maxstack));
  ptrdiff_t eofs = errinstack ? savestack(L, err) : 0;
  int status = LUA_OK;
  /* Every handler call is a call from C and takes one level of the C-call
  ** bound (PUC callclosemethod -> luaD_call); a thread that is closed from
  ** outside got the closer's count from the call site. Only a pending
  ** handler can hit the bound: closing a thread with no to-be-closed slots
  ** never calls one, so PUC does not error there. */
  while (L->tbcn > 0) {
    int32_t *list = mref(L->tbclist, int32_t);
    TValue *o = restorestack(L, list[L->tbcn-1]);
    cTValue *mo;
    TValue *top;
    int st;
    if (o < restorestack(L, lofs)) break;
    L->tbcn--;
    if (lj_err_ccallover_n(nest) || slack > LJ_MAX_CCALLSERR) {
      /* PUC fails this handler call inside its protected call: the error
      ** replaces the error object and the slot is dropped like a closed one.
      ** It must not stay registered: the callers reset the thread, and a
      ** thread reset by lua_closethread is used again. The same goes for
      ** handlers of an unwinding that is nested too deep on the C stack
      ** (see tbc_closeunwound in lj_err.c). */
      int errerr = (nest != LJ_MAX_CCALLS);
      if (errinstack) err = restorestack(L, eofs);
      setstrV(L, err, lj_err_str(L, errerr ? LJ_ERR_ERRERR : LJ_ERR_CSTKOV));
      status = errerr ? LUA_ERRERR : LUA_ERRRUN;
      continue;
    }
    lj_state_checkstack(L, LUA_MINSTACK);
    o = restorestack(L, list[L->tbcn]);  /* Re-derive after a possible realloc. */
    if (errinstack) err = restorestack(L, eofs);
    mo = lj_meta_lookup(L, o, MM_close);
    top = L->top;
    copyTV(L, top, mo);
    if (LJ_FR2) setnilV(top+1);
    copyTV(L, top+1+LJ_FR2, o);
    copyTV(L, top+2+LJ_FR2, err);
    L->top = top+3+LJ_FR2;
    {
      MSize onest = L->ccallnest, othrow = L->ccallthrow;
      MSize oslack = g->ccallslack;
      L->ccallnest = nest + 1;
      g->ccallslack = slack;
      st = lj_vm_pcall(L, top+1+LJ_FR2, 0+1, 0);  /* No results, no errfunc. */
      L->ccallnest = onest;
      L->ccallthrow = othrow;
      g->ccallslack = oslack;
    }
    if (st != LUA_OK) {  /* The error of a __close replaces the error. */
      if (errinstack) err = restorestack(L, eofs);
      copyTV(L, err, L->top-1);
      L->top--;
      status = st;
    }
  }
  return status;
}

/* 5.4 error path of a pcall/xpcall called from Lua (PUC ldo.c finishpcallk,
** luaF_close with yy=1): the pending slots of the protected call are closed
** from the VM, one handler call at a time, after the C stack of the error is
** gone, so a handler can yield and an error in it is caught by the same
** pcall. err_unwind leaves L->base at the protected function's frame (the
** anchor: its FRAME_PCALL link is intact, its function slot holds the thread
** as a dummy frame) and the error object at L->top-1, above the highest
** pending slot; cont_tbcerr gets here again after each handler with the error
** object at L->top-1 = o+1. Sets up the call of the next handler at or above
** the anchor and returns its base, or puts the error object into the pcall's
** result slot, sets L->base to the pcall frame and returns NULL. Layout for
** the slot o being closed: o+1 error object, o+2/o+3 continuation, o+4
** handler, o+5 frame link (the VM writes it: FRAME_CONT to the anchor),
** o+6 value, o+7 error object. Everything still pending is below o.
*/
TValue * LJ_FASTCALL lj_meta_tbcerr(lua_State *L)
{
  TValue *level = L->base;
  for (;;) {
    int32_t *list = mref(L->tbclist, int32_t);
    TValue *err = L->top - 1;
    TValue *o;
    cTValue *mo;
    MSize nest;
    if (L->tbcn == 0 || (o = restorestack(L, list[L->tbcn-1])) < level) {
      TValue *pbase = frame_prevd(level-1) + 1;
      copyTV(L, pbase, err);
      L->top = pbase + 1;
      L->base = pbase;
      /* The chain is done: bring a stack that a stack overflow enlarged back
      ** to its normal limit, now that the top is down at the pcall (the
      ** unwinding left it above the highest pending slot, where the relimit
      ** of err_unwind could not shrink it). The VM reloads BASE. */
      lj_state_relimitstack(L);
      return NULL;
    }
    L->tbcn--;
    if (err != o+1) copyTV(L, o+1, err);
    L->top = o+2;
    /* The handler is called from the pcall's nesting, as the C loop does
    ** (lj_meta_tbccloseall_at): the pcall is counted out when the chain is
    ** done, see vm_unwind_ff_tail. */
    nest = L->ccallnest;
    if (L->ccallbase < nest) nest--;
    if (lj_err_ccallover_n(nest)) {
      int errerr = (nest != LJ_MAX_CCALLS);
      setstrV(L, o+1, lj_err_str(L, errerr ? LJ_ERR_ERRERR : LJ_ERR_CSTKOV));
      continue;
    }
    {  /* The check can move the stack. */
      ptrdiff_t lofs = savestack(L, level), oofs = savestack(L, o);
      lj_state_checkstack(L, 6 + LUA_MINSTACK);
      level = restorestack(L, lofs);
      o = restorestack(L, oofs);
    }
    mo = lj_meta_lookup(L, o, MM_close);
    (o+2)->u64 = LJ_CONT_TBCERR;
    setframe_pc(o+3, &G(L)->bc_cfunc_ext);
    copyTV(L, o+4, mo);
    setnilV(o+5);
    copyTV(L, o+6, o);
    copyTV(L, o+7, o+1);
    L->top = o+8;
    L->base = level;
    return o+6;
  }
}

/* Close to-be-closed slots marked by lua_toclose when a C function returns.
** The VM calls this only on the slow path when L->tbcn != 0. Slots below the
** C function base belong to outer frames and stay pending. */
int LJ_FASTCALL lj_meta_tbcclose_cfunc(lua_State *L, TValue *base, int nresults)
{
  int32_t *list = mref(L->tbclist, int32_t);
  ptrdiff_t bofs = savestack(L, base), tofs = savestack(L, L->top);
  TValue *eslot;
  int st;
  if (L->tbcn == 0 || restorestack(L, list[L->tbcn-1]) < base)
    return nresults;
  eslot = L->top++;
  setnilV(eslot);
  st = lj_meta_tbccloseall(L, base, eslot);
  if (st != LUA_OK) {
    eslot = L->top-1;
    L->top = eslot+1;
    lj_err_throw(L, st);
  }
  L->base = restorestack(L, bofs);
  L->top = restorestack(L, tofs);
  return nresults;
}
