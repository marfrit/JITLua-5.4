/*
** Instruction dispatch handling.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#define lj_dispatch_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_func.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_meta.h"
#include "lj_debug.h"
#include "lj_state.h"
#include "lj_frame.h"
#include "lj_bc.h"
#include "lj_ff.h"
#include "lj_strfmt.h"
#if LJ_HASJIT
#include "lj_jit.h"
#endif
#if LJ_HASFFI
#include "lj_ccallback.h"
#endif
#include "lj_trace.h"
#include "lj_dispatch.h"
#if LJ_HASPROFILE
#include "lj_profile.h"
#endif
#include "lj_vm.h"
#include "lj_meta.h"
#include "luajit.h"

/* Bump GG_NUM_ASMFF in lj_dispatch.h as needed. Ugly. */
LJ_STATIC_ASSERT(GG_NUM_ASMFF == FF_NUM_ASMFUNC);

/* -- Dispatch table management ------------------------------------------- */

#if LJ_TARGET_MIPS
#include <math.h>
LJ_FUNCA_NORET void LJ_FASTCALL lj_ffh_coroutine_wrap_err(lua_State *L,
							  lua_State *co);
#if !LJ_HASJIT
#define lj_dispatch_stitch	lj_dispatch_ins
#endif
#if !LJ_HASPROFILE
#define lj_dispatch_profile	lj_dispatch_ins
#endif

#define GOTFUNC(name)	(ASMFunction)name,
static const ASMFunction dispatch_got[] = {
  GOTDEF(GOTFUNC)
};
#undef GOTFUNC
#endif

/* Initialize instruction dispatch table and hot counters. */
void lj_dispatch_init(GG_State *GG)
{
  uint32_t i;
  ASMFunction *disp = GG->dispatch;
  for (i = 0; i < GG_LEN_SDISP; i++)
    disp[GG_LEN_DDISP+i] = disp[i] = makeasmfunc(lj_bc_ofs[i]);
  for (i = GG_LEN_SDISP; i < GG_LEN_DDISP; i++)
    disp[i] = makeasmfunc(lj_bc_ofs[i]);
  /* The JIT engine is off by default. luaopen_jit() turns it on. */
  disp[BC_FORL] = disp[BC_IFORL];
  disp[BC_ITERL] = disp[BC_IITERL];
  /* Workaround for stable v2.1 bytecode. TODO: Replace with BC_IITERN. */
  disp[BC_ITERN] = &lj_vm_IITERN;
  disp[BC_LOOP] = disp[BC_ILOOP];
  disp[BC_FUNCF] = disp[BC_IFUNCF];
  disp[BC_FUNCV] = disp[BC_IFUNCV];
  GG->g.bc_cfunc_ext = GG->g.bc_cfunc_int = BCINS_AD(BC_FUNCC, LUA_MINSTACK, 0);
  for (i = 0; i < GG_NUM_ASMFF; i++)
    GG->bcff[i] = BCINS_AD(BC__MAX+i, 0, 0);
#if LJ_TARGET_MIPS
  memcpy(GG->got, dispatch_got, LJ_GOT__MAX*sizeof(ASMFunction *));
#endif
}

#if LJ_HASJIT
/* Initialize hotcount table. */
void lj_dispatch_init_hotcount(global_State *g)
{
  int32_t hotloop = G2J(g)->param[JIT_P_hotloop];
  HotCount start = (HotCount)(hotloop*HOTCOUNT_LOOP - 1);
  HotCount *hotcount = G2GG(g)->hotcount;
  uint32_t i;
  for (i = 0; i < HOTCOUNT_SIZE; i++)
    hotcount[i] = start;
}
#endif

/* Internal dispatch mode bits. */
#define DISPMODE_CALL	0x01	/* Override call dispatch. */
#define DISPMODE_RET	0x02	/* Override return dispatch. */
#define DISPMODE_INS	0x04	/* Override instruction dispatch. */
#define DISPMODE_JIT	0x10	/* JIT compiler on. */
#define DISPMODE_REC	0x20	/* Recording active. */
#define DISPMODE_PROF	0x40	/* Profiling active. */

/* Update dispatch table depending on various flags. */
void LJ_FASTCALL lj_dispatch_update(global_State *g, int nolock)
{
#if LJ_HASPROFILE && !LJ_PROFILE_SIGPROF
  int profile_locked = nolock ? 0 : lj_profile_lock();
#endif
  uint8_t oldmode = g->dispatchmode;
  uint8_t mode = 0;
#if LJ_HASJIT
  /* 5.4 debug hooks must see every line/count/call/return: while any hook
  ** event is set the JIT neither counts nor enters traces (debug.sethook
  ** also flushes existing traces, see lib_debug.c). */
  mode |= ((G2J(g)->flags & JIT_F_ON) && !(g->hookmask & HOOK_EVENTMASK)) ?
	    DISPMODE_JIT : 0;
  mode |= G2J(g)->state != LJ_TRACE_IDLE ?
	    (DISPMODE_REC|DISPMODE_INS|DISPMODE_CALL) : 0;
#endif
#if LJ_HASPROFILE
  mode |= (g->hookmask & HOOK_PROFILE) ? (DISPMODE_PROF|DISPMODE_INS) : 0;
#endif
  mode |= (g->hookmask & (LUA_MASKLINE|LUA_MASKCOUNT)) ? DISPMODE_INS : 0;
  mode |= (g->hookmask & LUA_MASKCALL) ? DISPMODE_CALL : 0;
  mode |= (g->hookmask & LUA_MASKRET) ? DISPMODE_RET : 0;
  if (oldmode != mode) {  /* Mode changed? */
    ASMFunction *disp = G2GG(g)->dispatch;
    ASMFunction f_forl, f_iterl, f_itern, f_loop, f_funcf, f_funcv;
    g->dispatchmode = mode;

    /* Hotcount if JIT is on, but not while recording. */
    if ((mode & (DISPMODE_JIT|DISPMODE_REC)) == DISPMODE_JIT) {
      f_forl = makeasmfunc(lj_bc_ofs[BC_FORL]);
      f_iterl = makeasmfunc(lj_bc_ofs[BC_ITERL]);
      f_itern = makeasmfunc(lj_bc_ofs[BC_ITERN]);
      f_loop = makeasmfunc(lj_bc_ofs[BC_LOOP]);
      f_funcf = makeasmfunc(lj_bc_ofs[BC_FUNCF]);
      f_funcv = makeasmfunc(lj_bc_ofs[BC_FUNCV]);
    } else {  /* Otherwise use the non-hotcounting instructions. */
      f_forl = disp[GG_LEN_DDISP+BC_IFORL];
      f_iterl = disp[GG_LEN_DDISP+BC_IITERL];
      f_itern = &lj_vm_IITERN;
      f_loop = disp[GG_LEN_DDISP+BC_ILOOP];
      f_funcf = makeasmfunc(lj_bc_ofs[BC_IFUNCF]);
      f_funcv = makeasmfunc(lj_bc_ofs[BC_IFUNCV]);
    }
    /* Init static counting instruction dispatch first (may be copied below). */
    disp[GG_LEN_DDISP+BC_FORL] = f_forl;
    disp[GG_LEN_DDISP+BC_ITERL] = f_iterl;
    disp[GG_LEN_DDISP+BC_ITERN] = f_itern;
    disp[GG_LEN_DDISP+BC_LOOP] = f_loop;

    /* Set dynamic instruction dispatch. */
    if ((oldmode ^ mode) & (DISPMODE_PROF|DISPMODE_REC|DISPMODE_INS)) {
      /* Need to update the whole table. */
      if (!(mode & DISPMODE_INS)) {  /* No ins dispatch? */
	/* Copy static dispatch table to dynamic dispatch table. */
	memcpy(&disp[0], &disp[GG_LEN_DDISP], GG_LEN_SDISP*sizeof(ASMFunction));
	/* Overwrite with dynamic return dispatch. */
	if ((mode & DISPMODE_RET)) {
	  disp[BC_RETM] = lj_vm_rethook;
	  disp[BC_RET] = lj_vm_rethook;
	  disp[BC_RET0] = lj_vm_rethook;
	  disp[BC_RET1] = lj_vm_rethook;
	}
      } else {
	/* The recording dispatch also checks for hooks. */
	ASMFunction f = (mode & DISPMODE_PROF) ? lj_vm_profhook :
			(mode & DISPMODE_REC) ? lj_vm_record : lj_vm_inshook;
	uint32_t i;
	for (i = 0; i < GG_LEN_SDISP; i++)
	  disp[i] = f;
      }
    } else if (!(mode & DISPMODE_INS)) {
      /* Otherwise set dynamic counting ins. */
      disp[BC_FORL] = f_forl;
      disp[BC_ITERL] = f_iterl;
      disp[BC_ITERN] = f_itern;
      disp[BC_LOOP] = f_loop;
      /* Set dynamic return dispatch. */
      if ((mode & DISPMODE_RET)) {
	disp[BC_RETM] = lj_vm_rethook;
	disp[BC_RET] = lj_vm_rethook;
	disp[BC_RET0] = lj_vm_rethook;
	disp[BC_RET1] = lj_vm_rethook;
      } else {
	disp[BC_RETM] = disp[GG_LEN_DDISP+BC_RETM];
	disp[BC_RET] = disp[GG_LEN_DDISP+BC_RET];
	disp[BC_RET0] = disp[GG_LEN_DDISP+BC_RET0];
	disp[BC_RET1] = disp[GG_LEN_DDISP+BC_RET1];
      }
    }

    /* Set dynamic call dispatch. */
    if ((oldmode ^ mode) & DISPMODE_CALL) {  /* Update the whole table? */
      uint32_t i;
      if ((mode & DISPMODE_CALL) == 0) {  /* No call hooks? */
	for (i = GG_LEN_SDISP; i < GG_LEN_DDISP; i++)
	  disp[i] = makeasmfunc(lj_bc_ofs[i]);
      } else {
	for (i = GG_LEN_SDISP; i < GG_LEN_DDISP; i++)
	  disp[i] = lj_vm_callhook;
      }
    }
    if (!(mode & DISPMODE_CALL)) {  /* Overwrite dynamic counting ins. */
      disp[BC_FUNCF] = f_funcf;
      disp[BC_FUNCV] = f_funcv;
    }

#if LJ_HASJIT
    /* Reset hotcounts for JIT off to on transition. */
    if ((mode & DISPMODE_JIT) && !(oldmode & DISPMODE_JIT))
      lj_dispatch_init_hotcount(g);
#endif
  }
#if LJ_HASPROFILE && !LJ_PROFILE_SIGPROF
  if (profile_locked) lj_profile_unlock();
#else
  UNUSED(nolock);
#endif
}

/* -- JIT mode setting ---------------------------------------------------- */

#if LJ_HASJIT
/* Set JIT mode for a single prototype. */
static void setptmode(global_State *g, GCproto *pt, int mode)
{
  if ((mode & LUAJIT_MODE_ON)) {  /* (Re-)enable JIT compilation. */
    pt->flags &= ~PROTO_NOJIT;
    lj_trace_reenableproto(pt);  /* Unpatch all ILOOP etc. bytecodes. */
  } else {  /* Flush and/or disable JIT compilation. */
    if (!(mode & LUAJIT_MODE_FLUSH))
      pt->flags |= PROTO_NOJIT;
    lj_trace_flushproto(g, pt);  /* Flush all traces of prototype. */
  }
}

/* Recursively set the JIT mode for all children of a prototype. */
static void setptmode_all(global_State *g, GCproto *pt, int mode)
{
  ptrdiff_t i;
  if (!(pt->flags & PROTO_CHILD)) return;
  for (i = -(ptrdiff_t)pt->sizekgc; i < 0; i++) {
    GCobj *o = proto_kgc(pt, i);
    if (o->gch.gct == ~LJ_TPROTO) {
      setptmode(g, gco2pt(o), mode);
      setptmode_all(g, gco2pt(o), mode);
    }
  }
}
#endif

/* Public API function: control the JIT engine. */
int luaJIT_setmode(lua_State *L, int idx, int mode)
{
  global_State *g = G(L);
  int mm = mode & LUAJIT_MODE_MASK;
  lj_trace_abort(g);  /* Abort recording on any state change. */
  /* Avoid pulling the rug from under our own feet. */
  if ((g->hookmask & HOOK_GC))
    lj_err_caller(L, LJ_ERR_NOGCMM);
  switch (mm) {
#if LJ_HASJIT
  case LUAJIT_MODE_ENGINE:
    if ((mode & LUAJIT_MODE_FLUSH)) {
      lj_trace_flushall(L);
    } else {
      if (!(mode & LUAJIT_MODE_ON))
	G2J(g)->flags &= ~(uint32_t)JIT_F_ON;
      else
	G2J(g)->flags |= (uint32_t)JIT_F_ON;
      lj_dispatch_update(g, 0);
    }
    break;
  case LUAJIT_MODE_FUNC:
  case LUAJIT_MODE_ALLFUNC:
  case LUAJIT_MODE_ALLSUBFUNC: {
    cTValue *tv = idx == 0 ? frame_prev(L->base-1)-LJ_FR2 :
		  idx > 0 ? L->base + (idx-1) : L->top + idx;
    GCproto *pt;
    if ((idx == 0 || tvisfunc(tv)) && isluafunc(&gcval(tv)->fn))
      pt = funcproto(&gcval(tv)->fn);  /* Cannot use funcV() for frame slot. */
    else if (tvisproto(tv))
      pt = protoV(tv);
    else
      return 0;  /* Failed. */
    if (mm != LUAJIT_MODE_ALLSUBFUNC)
      setptmode(g, pt, mode);
    if (mm != LUAJIT_MODE_FUNC)
      setptmode_all(g, pt, mode);
    break;
    }
  case LUAJIT_MODE_TRACE:
    if (!(mode & LUAJIT_MODE_FLUSH))
      return 0;  /* Failed. */
    lj_trace_flush(G2J(g), idx);
    break;
#else
  case LUAJIT_MODE_ENGINE:
  case LUAJIT_MODE_FUNC:
  case LUAJIT_MODE_ALLFUNC:
  case LUAJIT_MODE_ALLSUBFUNC:
    UNUSED(idx);
    if ((mode & LUAJIT_MODE_ON))
      return 0;  /* Failed. */
    break;
#endif
  case LUAJIT_MODE_WRAPCFUNC:
    if ((mode & LUAJIT_MODE_ON)) {
      if (idx != 0) {
	cTValue *tv = idx > 0 ? L->base + (idx-1) : L->top + idx;
	if (tvislightud(tv))
	  g->wrapf = (lua_CFunction)lightudV(g, tv);
	else
	  return 0;  /* Failed. */
      } else {
	return 0;  /* Failed. */
      }
      setbc_op(&g->bc_cfunc_ext, BC_FUNCCW);
    } else {
      setbc_op(&g->bc_cfunc_ext, BC_FUNCC);
    }
    break;
  default:
    return 0;  /* Failed. */
  }
  return 1;  /* OK. */
}

/* Enforce (dynamic) linker error for version mismatches. See luajit.c. */
LUA_API void LUAJIT_VERSION_SYM(void)
{
}

/* -- Hooks --------------------------------------------------------------- */

/* This function can be called asynchronously (e.g. during a signal). */
LUA_API int lua_sethook(lua_State *L, lua_Hook func, int mask, int count)
{
  global_State *g = G(L);
  mask &= HOOK_EVENTMASK;
  if (func == NULL || mask == 0) { mask = 0; func = NULL; }  /* Consistency. */
  g->hookf = func;
  g->hookcount = g->hookcstart = (int32_t)count;
  g->hookmask = (uint8_t)((g->hookmask & ~HOOK_EVENTMASK) | mask);
  g->ffretry = 0;
  lj_trace_abort(g);  /* Abort recording on any hook change. */
  lj_dispatch_update(g, 0);
  return 1;
}

LUA_API lua_Hook lua_gethook(lua_State *L)
{
  return G(L)->hookf;
}

LUA_API int lua_gethookmask(lua_State *L)
{
  return G(L)->hookmask & HOOK_EVENTMASK;
}

LUA_API int lua_gethookcount(lua_State *L)
{
  return (int)G(L)->hookcstart;
}

/* Call a hook. */
static void callhook(lua_State *L, int event, BCLine line,
		     MSize ftransfer, MSize ntransfer)
{
  global_State *g = G(L);
  lua_Hook hookf = g->hookf;
  if (hookf && !hook_active(g)) {
    lua_Debug ar;
    lj_trace_abort(g);  /* Abort recording on any hook call. */
    ar.event = event;
    ar.currentline = line;
    ar.istailcall = 0;
    ar.ftransfer = (unsigned short)ftransfer;
    ar.ntransfer = (unsigned short)ntransfer;
    /* Top frame, nextframe = NULL. */
    ar.i_ci = (int)((L->base-1) - tvref(L->stack));
    g->hookbase = (MSize)ar.i_ci;  /* lj_debug_funcname: 'hook' frames. */
    g->hookftransfer = ftransfer;  /* debug.getinfo(2, "r") in the hook. */
    g->hookntransfer = ntransfer;
    lj_state_checkstack(L, 1+LUA_MINSTACK);
#if LJ_HASPROFILE && !LJ_PROFILE_SIGPROF
    lj_profile_hook_enter(g);
#else
    hook_enter(g);
#endif
    hookf(L, &ar);
    lj_assertG(hook_active(g), "active hook flag removed");
    setgcref(g->cur_L, obj2gco(L));
#if LJ_HASPROFILE && !LJ_PROFILE_SIGPROF
    lj_profile_hook_leave(g);
#else
    hook_leave(g);
#endif
  }
}

/* -- Dispatch callbacks -------------------------------------------------- */

/* Calculate number of used stack slots in the current frame. */
static BCReg cur_topslot(GCproto *pt, const BCIns *pc, uint32_t nres)
{
  BCIns ins = pc[-1];
  if (bc_op(ins) == BC_UCLO)
    ins = pc[bc_j(ins)];
  switch (bc_op(ins)) {
  case BC_CALLM: case BC_CALLMT: return bc_a(ins) + bc_c(ins) + nres-1+1+LJ_FR2;
  case BC_RETM: return bc_a(ins) + bc_d(ins) + nres-1;
  case BC_TSETM: return bc_a(ins) + nres-1;
  default: return pt->framesize;
  }
}

/* Instruction dispatch. Used by instr/line/return hooks or when recording. */
void LJ_FASTCALL lj_dispatch_ins(lua_State *L, const BCIns *pc)
{
  ERRNO_SAVE
  GCfunc *fn = curr_func(L);
  GCproto *pt = funcproto(fn);
  void *cf = cframe_raw(L->cframe);
  const BCIns *oldpc = cframe_pc(cf);
  global_State *g = G(L);
  BCReg slots;
  setcframe_pc(cf, pc);
  slots = cur_topslot(pt, pc, cframe_multres_n(cf));
  L->top = L->base + slots;  /* Fix top. */
#if LJ_HASJIT
  {
    jit_State *J = G2J(g);
    if (J->state != LJ_TRACE_IDLE) {
#ifdef LUA_USE_ASSERT
      ptrdiff_t delta = L->top - L->base;
#endif
      J->L = L;
      lj_trace_ins(J, pc-1);  /* The interpreter bytecode PC is offset by 1. */
      lj_assertG(L->top - L->base == delta,
		 "unbalanced stack after tracing of instruction");
    }
  }
#endif
  if ((g->hookmask & LUA_MASKCOUNT) && g->hookcount == 0) {
    g->hookcount = g->hookcstart;
    callhook(L, LUA_HOOKCOUNT, -1, 0, 0);
    L->top = L->base + slots;  /* Fix top again. */
  }
  if ((g->hookmask & LUA_MASKLINE)) {
    BCPos npc = proto_bcpos(pt, pc) - 1;
    int stripped = proto_lineinfo(pt) == NULL;
    BCLine line = stripped ? -1 : lj_debug_line(pt, npc);  /* 5.4: nil. */
    BCOp op = bc_op(pc[-1]);
    int newline;
    if (op == BC_LOOP || op == BC_ILOOP || op == BC_JLOOP) {
      /* LuaJIT's loop-counting op for while/repeat has no PUC counterpart:
      ** no line event, and the previous pc stays the reference. */
      setcframe_pc(cf, oldpc);
      newline = 0;
    } else if (oldpc <= proto_bc(pt) || oldpc > proto_bc(pt) + pt->sizebc) {
      /* The previous instruction ran in another function (or there is
      ** none): entering this one (first body instruction, after the FUNC*
      ** header at 0) is a new line; returning into it continues the call's
      ** line unless the line changed (PUC 5.4 rethook sets oldpc to the
      ** call). */
      newline = npc <= 1 || (!stripped && line != lj_debug_line(pt, npc-1));
    } else {
      BCPos opc = proto_bcpos(pt, oldpc) - 1;
      newline = pc <= oldpc || (!stripped && line != lj_debug_line(pt, opc));
    }
    if (newline) {
      callhook(L, LUA_HOOKLINE, line, 0, 0);
      L->top = L->base + slots;  /* Fix top again. */
    }
  }
  if ((g->hookmask & LUA_MASKRET)) {
    BCIns ins = pc[-1];
    BCOp op = bc_op(ins);
    if (bc_isret(op)) {  /* 5.4 'r': results are at RA.. (RET0: none). */
      MSize n = op == BC_RET0 ? 0 : op == BC_RET1 ? 1 :
		op == BC_RETM ? bc_d(ins) + cframe_multres_n(cf) - 1 :
		bc_d(ins) - 1;
      callhook(L, LUA_HOOKRET, -1, n ? bc_a(ins) + 1 : 0, n);
    }
  }
  ERRNO_RESTORE
}

/* Return hook for C functions (5.4: C functions get return events, also
** debug.sethook itself). Called from the FUNCC/FUNCCW VM code right after
** the function returned n results, if LUA_MASKRET is set by then.
*/
/* Return hook for ASM fast functions, called from fff_res with the n results
** already in place at base-2 (over the function and link slots). The frame
** is reconstituted for the hook (the results move up two slots) and the
** results are moved back afterwards. The function comes from the call hook
** (L->hookff); fast functions that reach fff_res run no Lua code in between.
*/
int LJ_FASTCALL lj_dispatch_ffret(lua_State *L, int n, const BCIns *pc)
{
  global_State *g = G(L);
  GCfunc *fn;
  if (hook_active(g)) return n;  /* Fast functions called by the hook. */
  fn = mref(L->hookff, GCfunc);
  setmref(L->hookff, NULL);
  if (fn && (g->hookmask & LUA_MASKRET) && n >= 0) {
    ERRNO_SAVE
    ptrdiff_t baseofs = savestack(L, L->base);
    TValue *base;
    L->top = L->base + n;
    lj_state_checkstack(L, (MSize)n + 2 + LUA_MINSTACK);
    base = restorestack(L, baseofs);
    memmove(base, base-2, (size_t)n*sizeof(TValue));
    setfuncV(L, base-2, fn);
    setframe_pc(base-1, pc);
    L->top = base + n;
    callhook(L, LUA_HOOKRET, -1, n ? 1 : 0, (MSize)n);
    base = restorestack(L, baseofs);
    memmove(base-2, base, (size_t)n*sizeof(TValue));
    ERRNO_RESTORE
  }
  return n;
}

/* Return hook for pcall/xpcall/coroutine.resume/wrap (5.4: C functions with
** a return event). Called from the VM with the n results at res and the
** frame still intact, L->base set to the function's base. The VM prepends
** the status boolean afterwards (that may overwrite the frame link), so the
** hook sees it via a temporary copy of the results shifted up by one slot
** (prepend = 0/1; 2 for none). Returns res, which moves if the hook grew
** the stack.
*/
TValue * LJ_FASTCALL lj_dispatch_pret(lua_State *L, TValue *res, int n,
				      int prepend)
{
  global_State *g = G(L);
  if ((g->hookmask & LUA_MASKRET) && !hook_active(g)) {
    ERRNO_SAVE
    ptrdiff_t resofs = savestack(L, res);
    L->top = res + n;
    if (prepend < 2) {
      lj_state_checkstack(L, (MSize)n + 1 + LUA_MINSTACK);
      res = restorestack(L, resofs);
      memmove(res+1, res, (size_t)n*sizeof(TValue));
      setboolV(res, prepend);
      n++;
      L->top = res + n;
    }
    callhook(L, LUA_HOOKRET, -1, (MSize)(res - L->base) + 1, (MSize)n);
    res = restorestack(L, resofs);
    if (prepend < 2)
      memmove(res, res+1, (size_t)(n-1)*sizeof(TValue));
    ERRNO_RESTORE
  }
  return res;
}

int LJ_FASTCALL lj_dispatch_cret(lua_State *L, int n)
{
  /* n >= 0: a negative count is a yield, whose pending slots lua_yield
  ** already closed (it cannot leave them to a C continuation frame). The
  ** check is thread-wide: any pending slot, including a Lua <close> local of
  ** an outer frame, routes every later C return through here. That is
  ** correct (the closer keeps slots below this C frame pending) and only
  ** costs the one call while something is pending. */
  if (n >= 0 && L->tbcn)
    n = lj_meta_tbcclose_cfunc(L, L->base, n);
  if (n >= 0 && (G(L)->hookmask & LUA_MASKRET)) {  /* Not a yield. */
    ERRNO_SAVE
    MSize ftransfer = n ? (MSize)((L->top - n) - L->base) + 1 : 0;
    callhook(L, LUA_HOOKRET, -1, ftransfer, (MSize)n);
    ERRNO_RESTORE
  }
  return n;
}

/* Initialize call. Ensure stack space and return # of missing parameters. */
static int call_init(lua_State *L, GCfunc *fn)
{
  if (isluafunc(fn)) {
    GCproto *pt = funcproto(fn);
    int numparams = pt->numparams;
    int gotparams = (int)(L->top - L->base);
    int need = pt->framesize;
    if ((pt->flags & PROTO_VARARG)) need += 1+LJ_FR2+gotparams;
    lj_state_checkstack(L, (MSize)need);
    numparams -= gotparams;
    return numparams >= 0 ? numparams : 0;
  } else {
    lj_state_checkstack(L, LUA_MINSTACK);
    return 0;
  }
}

/* Call dispatch. Used by call hooks, hot calls or when recording. */
ASMFunction LJ_FASTCALL lj_dispatch_call(lua_State *L, const BCIns *pc)
{
  ERRNO_SAVE
  GCfunc *fn = curr_func(L);
  BCOp op;
  global_State *g = G(L);
#if LJ_HASJIT
  jit_State *J = G2J(g);
#endif
  int missing = call_init(L, fn);
  int retry = (int)g->ffretry;  /* Fast function re-dispatched after FFH_RETRY. */
  g->ffretry = 0;
#if LJ_HASJIT
  J->L = L;
  if ((uintptr_t)pc & 1) {  /* Marker for hot call. */
#ifdef LUA_USE_ASSERT
    ptrdiff_t delta = L->top - L->base;
#endif
    pc = (const BCIns *)((uintptr_t)pc & ~(uintptr_t)1);
    lj_trace_hot(J, pc);
    lj_assertG(L->top - L->base == delta,
	       "unbalanced stack after hot call");
    goto out;
  } else if (J->state != LJ_TRACE_IDLE &&
	     !(g->hookmask & (HOOK_GC|HOOK_VMEVENT))) {
#ifdef LUA_USE_ASSERT
    ptrdiff_t delta = L->top - L->base;
#endif
    /* Record the FUNC* bytecodes, too. */
    lj_trace_ins(J, pc-1);  /* The interpreter bytecode PC is offset by 1. */
    lj_assertG(L->top - L->base == delta,
	       "unbalanced stack after hot instruction");
  }
#endif
  if ((g->hookmask & LUA_MASKCALL) && !hook_active(g)) {
    int i;
    /* 5.4 "tail call" event: BC_CALLT marked the frame. C callees get a
    ** plain "call", their frame is never marked. */
    int tail = frame_istail(L->base-1);
    MSize nparams = isluafunc(fn) ? funcproto(fn)->numparams :
				    (MSize)(L->top - L->base);
    /* An ASM fast function whose fallback handler returned FFH_RETRY is
    ** re-dispatched through its header: that is the same call, no second
    ** event. Its return event comes from lj_dispatch_ffret() (hookff). */
    int isasmff = bc_op(pc[-1]) >= BC__MAX;
    setmref(L->hookff, isasmff ? fn : NULL);
    if (!retry) {
      for (i = 0; i < missing; i++)  /* Add missing parameters. */
	setnilV(L->top++);
      callhook(L, tail ? LUA_HOOKTAILCALL : LUA_HOOKCALL, -1, nparams ? 1 : 0,
	       nparams);
      /* Preserve modifications of missing parameters by lua_setlocal(). */
      while (missing-- > 0 && tvisnil(L->top - 1))
	L->top--;
    }
  }
#if LJ_HASJIT
out:
#endif
  op = bc_op(pc[-1]);  /* Get FUNC* op. */
#if LJ_HASJIT
  /* Use the non-hotcounting variants if JIT is off or while recording. */
  if ((!(J->flags & JIT_F_ON) || J->state != LJ_TRACE_IDLE) &&
      (op == BC_FUNCF || op == BC_FUNCV))
    op = (BCOp)((int)op+(int)BC_IFUNCF-(int)BC_FUNCF);
#endif
  ERRNO_RESTORE
  return makeasmfunc(lj_bc_ofs[op]);  /* Return static dispatch target. */
}

#if LJ_HASJIT
/* Stitch a new trace. */
void LJ_FASTCALL lj_dispatch_stitch(jit_State *J, const BCIns *pc)
{
  if (!(J2G(J)->hookmask & HOOK_VMEVENT)) {
    ERRNO_SAVE
    lua_State *L = J->L;
    void *cf = cframe_raw(L->cframe);
    const BCIns *oldpc = cframe_pc(cf);
    setcframe_pc(cf, pc);
    /* Before dispatch, have to bias PC by 1. */
    L->top = L->base + cur_topslot(curr_proto(L), pc+1, cframe_multres_n(cf));
    lj_trace_stitch(J, pc-1);  /* Point to the CALL instruction. */
    setcframe_pc(cf, oldpc);
    ERRNO_RESTORE
  }
}
#endif

#if LJ_HASPROFILE
/* Profile dispatch. */
void LJ_FASTCALL lj_dispatch_profile(lua_State *L, const BCIns *pc)
{
  ERRNO_SAVE
  GCfunc *fn = curr_func(L);
  GCproto *pt = funcproto(fn);
  void *cf = cframe_raw(L->cframe);
  const BCIns *oldpc = cframe_pc(cf);
  global_State *g;
  setcframe_pc(cf, pc);
  L->top = L->base + cur_topslot(pt, pc, cframe_multres_n(cf));
  lj_profile_interpreter(L);
  setcframe_pc(cf, oldpc);
  g = G(L);
  setgcref(g->cur_L, obj2gco(L));
  setvmstate(g, INTERP);
  ERRNO_RESTORE
}
#endif

