/*
** Boxed interned 64-bit integers (ADR-001b, LuaJIT-5.4 port).
** See docs/adr-001b-boxed-i64.md.
**
** A Lua 5.4 integer that does not fit into int32 becomes an immutable GCudata
** holding one int64_t, with a private udtype (UDTYPE_I64BOX) as the marker.
** No new GC tag is used: the GC64 tag encoding drops a tag's bit 0 in the
** VM's 17-bit form, so a new tag (and even moving LJ_TNUMX) breaks agreement
** between the C side and the interpreter -- measured this session.
**
** The objects are interned in a table anchored in the registry: keys are the
** 8 raw bytes of the value (as an interned binary string), values are the
** objects. Interning makes pointer equality equal to value equality, which
** keeps raw comparison, table keys and the same-type GC-pointer compares
** correct without new compare code on the fast paths.
**
** Spike note: keying by an interned 8-byte string costs an extra string
** intern per new value. A dedicated i64 intern hash (like g->str) is the
** follow-up if the numbers in tests/bench say it matters.
**
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#define lj_i64_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_udata.h"
#include "lj_state.h"

#include "lj_i64.h"

int LJ_FASTCALL lj_i64_isnum(cTValue *o)
{
  return tvisi64(o);
}

GCudata *lj_i64_box(lua_State *L, int64_t v)
{
  GCtab *reg = tabV(registry(L));
  GCstr *k = lj_str_new(L, (const char *)&v, sizeof(v));
  cTValue *o = lj_tab_getstr(reg, k);
  if (o != NULL && tvisi64(o))
    return udataV(o);  /* Already interned. */
  {
    /* Userdata must never have a NULL env: gc_mark() unconditionally marks it. */
    GCudata *ud = lj_udata_new(L, sizeof(int64_t), tabref(L->env));
    TValue key;
    TValue *slot;
    ud->udtype = UDTYPE_I64BOX;
    *(int64_t *)uddata(ud) = v;
    setstrV(L, &key, k);
    slot = lj_tab_set(L, reg, &key);
    setudataV(L, slot, ud);
    lj_gc_anybarriert(L, reg);  /* The registry table may be black. */
    return ud;
  }
}

void lj_i64_push(lua_State *L, int64_t v)
{
  setudataV(L, L->top, lj_i64_box(L, v));
  incr_top(L);
}
