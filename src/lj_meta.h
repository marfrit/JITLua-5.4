/*
** Metamethod handling.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_META_H
#define _LJ_META_H

#include "lj_obj.h"

/* Metamethod handling */
LJ_FUNC void lj_meta_init(lua_State *L);
LJ_FUNC cTValue *lj_meta_cache(GCtab *mt, MMS mm, GCstr *name);
LJ_FUNC cTValue *lj_meta_lookup(lua_State *L, cTValue *o, MMS mm);
#if LJ_HASFFI
LJ_FUNC int lj_meta_tailcall(lua_State *L, cTValue *tv);
#endif

#define lj_meta_fastg(g, mt, mm) \
  ((mt) == NULL ? NULL : ((mt)->nomm & (1u<<(mm))) ? NULL : \
   lj_meta_cache(mt, mm, mmname_str(g, mm)))
#define lj_meta_fast(L, mt, mm)	lj_meta_fastg(G(L), mt, mm)

/* Return values of lj_meta_for. */
#define LJ_FOR_RETRY	0	/* slots prepared, re-execute FORI/JFORI */
#define LJ_FOR_SKIP	1	/* PUC forprep skipped the loop: jump past it */
#define LJ_FOR_WIDE	2	/* loop entered from C (wide, clipped, or a limit
				** equal to the clip value): enter the body */

/* C helpers for some instructions, called from assembler VM. */
LJ_FUNCA cTValue *lj_meta_tget(lua_State *L, cTValue *o, cTValue *k);
LJ_FUNCA cTValue *lj_meta_tget_env(lua_State *L, cTValue *o, cTValue *k);
LJ_FUNCA TValue *lj_meta_tset(lua_State *L, cTValue *o, cTValue *k);
LJ_FUNCA TValue *lj_meta_tset_env(lua_State *L, cTValue *o, cTValue *k);
LJ_FUNCA TValue *lj_meta_arith(lua_State *L, TValue *ra, cTValue *rb,
			       cTValue *rc, BCReg op);
LJ_FUNCA TValue *lj_meta_bitop(lua_State *L, TValue *ra, cTValue *rb,
			    cTValue *rc, BCReg op);
LJ_FUNCA TValue *lj_meta_cat(lua_State *L, TValue *top, int left);
LJ_FUNCA TValue * LJ_FASTCALL lj_meta_len(lua_State *L, cTValue *o);
LJ_FUNCA TValue *lj_meta_equal(lua_State *L, GCobj *o1, GCobj *o2, int ne);
LJ_FUNCA TValue *lj_meta_equal_any(lua_State *L, uint64_t a, uint64_t b,
				   int ne);
LJ_FUNCA TValue * LJ_FASTCALL lj_meta_equal_cd(lua_State *L, BCIns ins);
LJ_FUNCA TValue *lj_meta_comp(lua_State *L, cTValue *o1, cTValue *o2, int op);
LJ_FUNCA void lj_meta_istype(lua_State *L, BCReg ra, BCReg tp);
/* The x64 (GC64) and arm64 interpreters follow a whole __call chain and
** rebase after lj_meta_call, which may move the stack. The others resolve
** one level, as before. The recorder must model what its interpreter does. */
#if LJ_FR2 && (LJ_TARGET_X64 || LJ_TARGET_ARM64)
#define LJ_META_CALLCHAIN	1
#else
#define LJ_META_CALLCHAIN	0
#endif
LJ_FUNCA TValue *lj_meta_call(lua_State *L, TValue *func, TValue *top);
/* Lua 5.4 numeric 'for': lj_meta_for prepares the loop (PUC forprep) and says
** what the FORI stub has to do (LJ_FOR_*); lj_meta_forl runs one iteration of
** an integer loop that is not small (PUC OP_FORLOOP's integer branch) and
** returns the body PC to continue or NULL; lj_meta_forkind is the recorder's
** side-effect free view of a FORI. */
LJ_FUNCA int LJ_FASTCALL lj_meta_for(lua_State *L, TValue *o);
LJ_FUNCA const BCIns * LJ_FASTCALL lj_meta_forl(lua_State *L, TValue *o);
LJ_FUNC int lj_meta_forkind(lua_State *L, cTValue *o, TValue *out);
LJ_FUNCA const BCIns * LJ_FASTCALL lj_meta_forclip(lua_State *L, TValue *o);
LJ_FUNC int lj_meta_forview(lua_State *L, TValue *o, MSize k, TValue *dst);
LJ_FUNC void lj_meta_forunclip(lua_State *L, TValue *o);
LJ_FUNC void lj_meta_forclipfree(global_State *g, lua_State *L);
/* 5.4 to-be-closed variables. */
LJ_FUNCA void LJ_FASTCALL lj_meta_tbcmark(lua_State *L, TValue *o);
LJ_FUNCA TValue *lj_meta_tbcclose(lua_State *L, TValue *level, MSize multres);
LJ_FUNC int lj_meta_tbccloseall(lua_State *L, TValue *level, TValue *err);
LJ_FUNCA TValue * LJ_FASTCALL lj_meta_tbcerr(lua_State *L);
LJ_FUNC int lj_meta_tbccloseall_at(lua_State *L, TValue *level, TValue *err,
				   MSize nest, MSize slack);
LJ_FUNCA int LJ_FASTCALL lj_meta_tbcclose_cfunc(lua_State *L, TValue *base,
						int nresults);
LJ_FUNC void lj_meta_tbcfree(global_State *g, lua_State *L);

#endif
