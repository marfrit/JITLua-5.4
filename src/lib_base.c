/*
** Base and coroutine library.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2011 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#include <stdio.h>
#include <string.h>

#define lib_base_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_debug.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_func.h"
#include "lj_meta.h"
#include "lj_state.h"
#include "lj_frame.h"
#if LJ_HASFFI
#include "lj_ctype.h"
#include "lj_cconv.h"
#endif
#include "lj_bc.h"
#include "lj_ff.h"
#include "lj_dispatch.h"
#include "lj_char.h"
#include "lj_strscan.h"
#include "lj_strfmt.h"
#include "lj_lib.h"
#include "lj_i64.h"

/* -- Base library: checks ------------------------------------------------ */

#define LJLIB_MODULE_base

LJLIB_ASM(assert)		LJLIB_REC(.)
{
  lj_lib_checkany(L, 1);
  if (L->top == L->base+1)
    lj_err_caller(L, LJ_ERR_ASSERT);
  else if (tvisstr(L->base+1) || tvisnumber(L->base+1))
    lj_err_callermsg(L, strdata(lj_lib_checkstr(L, 2)));
  else
    lj_err_run(L);
  return FFH_UNREACHABLE;
}

/* ORDER LJ_T */
LJLIB_PUSH("nil")
LJLIB_PUSH("boolean")
LJLIB_PUSH(top-1)  /* boolean */
LJLIB_PUSH("userdata")
LJLIB_PUSH("string")
LJLIB_PUSH("upval")
LJLIB_PUSH("thread")
LJLIB_PUSH("proto")
LJLIB_PUSH("function")
LJLIB_PUSH("trace")
LJLIB_PUSH("cdata")
LJLIB_PUSH("table")
LJLIB_PUSH(top-9)  /* userdata */
LJLIB_PUSH("number")
/* Lua 5.4 type(): a boxed 64-bit integer is a number (ADR-001b). The asm fast
** function would report 'userdata' for the private udtype, and fixing that in
** seven backends is unnecessary -- the C form is correct everywhere. */
LJLIB_CF(type)			LJLIB_REC(.)
{
  cTValue *o = lj_lib_checkany(L, 1);
  const char *tname = tvisi64(o) ? "number" : lj_typename(o);
  setstrV(L, L->top-1, lj_str_newz(L, tname));
  return 1;
}

/* -- Base library: iterators --------------------------------------------- */

/* This solves a circular dependency problem -- change FF_next_N as needed. */
LJ_STATIC_ASSERT((int)FF_next == FF_next_N);

LJLIB_ASM(next)			LJLIB_REC(.)
{
  lj_lib_checktab(L, 1);
  lj_err_msg(L, LJ_ERR_NEXTIDX);
  return FFH_UNREACHABLE;
}

#if LJ_52 || LJ_HASFFI
static int ffh_pairs(lua_State *L, MMS mm)
{
  TValue *o = lj_lib_checkany(L, 1);
  cTValue *mo = lj_meta_lookup(L, o, mm);
  /* 5.4 honors __pairs (and FFI cdata metamethods), but NOT __ipairs. */
  if ((mm == MM_pairs || tviscdata(o)) && !tvisnil(mo)) {
    L->top = o+1;  /* Only keep one argument. */
    copyTV(L, L->base-1-LJ_FR2, mo);  /* Replace callable. */
    return FFH_TAILCALL;
  } else {
    if (!tvistab(o)) lj_err_argt(L, 1, LUA_TTABLE);
    if (LJ_FR2) { copyTV(L, o-1, o); o--; }
    setfuncV(L, o-1, funcV(lj_lib_upvalue(L, 1)));
    if (mm == MM_pairs) setnilV(o+1); else setintV(o+1, 0);
    return FFH_RES(3);
  }
}
#else
#define ffh_pairs(L, mm)	(lj_lib_checktab(L, 1), FFH_UNREACHABLE)
#endif

LJLIB_PUSH(lastcl)
LJLIB_ASM(pairs)		LJLIB_REC(xpairs 0)
{
  return ffh_pairs(L, MM_pairs);
}

/* 5.3+: ipairs respects __index (t[i] with metamethods, stop at the first
** nil). The ASM fast path handles tables without a metatable; a table with
** one lands here, as do non-integer keys. */
LJLIB_NOREGUV LJLIB_ASM(ipairs_aux)	LJLIB_REC(.)
{
  GCtab *t = lj_lib_checktab(L, 1);
  int32_t i = lj_lib_checkint(L, 2) + 1;
  if (!tabref(t->metatable)) return FFH_RETRY;  /* Fast path (int key now). */
  L->top = L->base + 2;
  lua_pushinteger(L, (lua_Integer)i);
  lua_gettable(L, 1);  /* Runs __index. */
  setintV(L->base-1-LJ_FR2, i);
  if (tvisnil(L->top-1)) {
    setnilV(L->base-1-LJ_FR2);
    return FFH_RES(1);
  }
  copyTV(L, L->base-LJ_FR2, L->top-1);
  return FFH_RES(2);
}

LJLIB_PUSH(lastcl)
LJLIB_ASM(ipairs)		LJLIB_REC(xpairs 1)
{
  return ffh_pairs(L, MM_ipairs);
}

/* -- Base library: getters and setters ----------------------------------- */

LJLIB_ASM_(getmetatable)	LJLIB_REC(.)
/* Recycle the lj_lib_checkany(L, 1) from assert. */

LJLIB_ASM(setmetatable)		LJLIB_REC(.)
{
  GCtab *t = lj_lib_checktab(L, 1);
  GCtab *mt = lj_lib_checktabornil(L, 2);
  if (!tvisnil(lj_meta_lookup(L, L->base, MM_metatable)))
    lj_err_caller(L, LJ_ERR_PROTMT);
  if (mt) setgcref(t->metatable, obj2gco(mt));
  else setgcrefnull(t->metatable);
  if (mt) { lj_gc_objbarriert(L, t, mt); }
  lj_gc_checkfinalizer(L, obj2gco(t), mt);
  settabV(L, L->base-1-LJ_FR2, t);
  return FFH_RES(1);
}

LJLIB_CF(getfenv)		LJLIB_REC(.)
{
  GCfunc *fn;
  cTValue *o = L->base;
  if (!(o < L->top && tvisfunc(o))) {
    int level = lj_lib_optint(L, 1, 1);
    if (level < 0)
      lj_err_arg(L, 1, LJ_ERR_INVLVL);
    o = lj_debug_frame(L, level, &level);
    if (o == NULL)
      lj_err_arg(L, 1, LJ_ERR_INVLVL);
    if (LJ_FR2) o--;
  }
  fn = &gcval(o)->fn;
  if (isluafunc(fn))
    copyTV(L, L->top++, &fn->l.envv);
  else
    settabV(L, L->top++, tabref(L->env));
  return 1;
}

LJLIB_CF(setfenv)
{
  GCfunc *fn;
  GCtab *t = lj_lib_checktab(L, 2);
  cTValue *o = L->base;
  if (!(o < L->top && tvisfunc(o))) {
    int level = lj_lib_checkint(L, 1);
    if (level == 0) {
      /* NOBARRIER: A thread (i.e. L) is never black. */
      setgcref(L->env, obj2gco(t));
      return 0;
    }
    if (level < 0)
      lj_err_arg(L, 1, LJ_ERR_INVLVL);
    o = lj_debug_frame(L, level, &level);
    if (o == NULL)
      lj_err_arg(L, 1, LJ_ERR_INVLVL);
    if (LJ_FR2) o--;
  }
  fn = &gcval(o)->fn;
  if (!isluafunc(fn))
    lj_err_caller(L, LJ_ERR_SETFENV);
  setgcref(fn->l.env, obj2gco(t));
  settabV(L, &fn->l.envv, t);
  lj_gc_objbarrier(L, obj2gco(fn), t);
  setfuncV(L, L->top++, fn);
  return 1;
}

LJLIB_ASM(rawget)		LJLIB_REC(.)
{
  lj_lib_checktab(L, 1);
  lj_lib_checkany(L, 2);
  return FFH_UNREACHABLE;
}

LJLIB_CF(rawset)		LJLIB_REC(.)
{
  lj_lib_checktab(L, 1);
  lj_lib_checkany(L, 2);
  L->top = 1+lj_lib_checkany(L, 3);
  lua_rawset(L, 1);
  return 1;
}

LJLIB_CF(rawequal)		LJLIB_REC(.)
{
  cTValue *o1 = lj_lib_checkany(L, 1);
  cTValue *o2 = lj_lib_checkany(L, 2);
  setboolV(L->top-1, lj_obj_equal(o1, o2));
  return 1;
}

/* Lua 5.4: rawlen bypasses __len (tables and strings only). */
LJLIB_CF(rawlen)		LJLIB_REC(.)
{
  TValue *o = lj_lib_checkany(L, 1);
  if (tvisstr(o)) {
    setintV(L->top-1, (int32_t)strV(o)->len);
  } else if (tvistab(o)) {
    setintV(L->top-1, (int32_t)lj_tab_len(tabV(o)));
  } else {
    lj_err_argtype(L, 1, "table or string");
  }
  return 1;
}


LJLIB_CF(unpack)		LJLIB_REC(.)
{
  GCtab *t = lj_lib_checktab(L, 1);
  int32_t n, i = lj_lib_optint(L, 2, 1);
  int32_t e = (L->base+3-1 < L->top && !tvisnil(L->base+3-1)) ?
	      lj_lib_checkint(L, 3) : (int32_t)lj_tab_len(t);
  uint32_t nu;
  if (i > e) return 0;
  nu = (uint32_t)e - (uint32_t)i;
  n = (int32_t)(nu+1);
  if (nu >= LUAI_MAXCSTACK || !lua_checkstack(L, n))
    lj_err_caller(L, LJ_ERR_UNPACK);
  do {
    cTValue *tv = lj_tab_getint(t, i);
    if (tv) {
      copyTV(L, L->top++, tv);
    } else {
      setnilV(L->top++);
    }
    if (i >= e) break;
    i++;
  } while (1);
  return n;
}

LJLIB_CF(select)		LJLIB_REC(.)
{
  int32_t n = (int32_t)(L->top - L->base);
  if (n >= 1 && tvisstr(L->base) && *strVdata(L->base) == '#') {
    setintV(L->top-1, n-1);
    return 1;
  } else {
    int32_t i = lj_lib_checkint(L, 1);
    if (i < 0) i = n + i; else if (i > n) i = n;
    if (i < 1)
      lj_err_arg(L, 1, LJ_ERR_IDXRNG);
    return n - i;
  }
}

/* -- Base library: conversions ------------------------------------------- */

LJLIB_ASM(tonumber)		LJLIB_REC(.)
{
  int32_t base = lj_lib_optint(L, 2, 10);
  /* PUC 5.4: without an explicit base, tonumber uses the Lua numeral syntax
  ** (0x... allowed); an explicit base 10 goes through the base parser, which
  ** rejects a 0x prefix. */
  int nobase = L->base + 1 >= L->top || tvisnil(L->base+1);
  if (base == 10 && nobase) {
    TValue *o = lj_lib_checkany(L, 1);
    /* 5.4 tonumber does not accept "inf"/"nan" (unlike some LuaJIT paths). */
    if (tvisstr(o)) {
      const char *p = strdata(strV(o));
      while (lj_char_isspace((unsigned char)(*p))) p++;
      if (*p == '+' || *p == '-') p++;
      if ((p[0] | 0x20) == 'i' || (p[0] | 0x20) == 'n') {
	setnilV(L->base-1-LJ_FR2);
	return FFH_RES(1);
      }
    }
    if (lj_strscan_numberobj64(L, o)) {  /* 5.4: integers of any size. */
      copyTV(L, L->base-1-LJ_FR2, o);
      return FFH_RES(1);
    }
#if LJ_HASFFI
    if (tviscdata(o)) {
      CTState *cts = ctype_cts(L);
      CType *ct = lj_ctype_rawref(cts, cdataV(o)->ctypeid);
      if (ctype_isenum(ct->info)) ct = ctype_child(cts, ct);
      if (ctype_isnum(ct->info) || ctype_iscomplex(ct->info)) {
	if (LJ_DUALNUM && ctype_isinteger_or_bool(ct->info) &&
	    ct->size <= 4 && !(ct->size == 4 && (ct->info & CTF_UNSIGNED))) {
	  int32_t i;
	  lj_cconv_ct_tv(cts, ctype_get(cts, CTID_INT32), (uint8_t *)&i, o, 0);
	  setintV(L->base-1-LJ_FR2, i);
	  return FFH_RES(1);
	}
	lj_cconv_ct_tv(cts, ctype_get(cts, CTID_DOUBLE),
		       (uint8_t *)&(L->base-1-LJ_FR2)->n, o, 0);
	return FFH_RES(1);
      }
    }
#endif
  } else {
    GCstr *str = lj_lib_checkstr(L, 1);
    const char *p = strdata(str);
    const char *pend = p + str->len;  /* embedded NULs are not a terminator */
    char *ep;
    unsigned int neg = 0;
    unsigned long long ul;
    if (base < 2 || base > 36) {
      /* PUC 5.4 luaL_argerror carries the caller location; LuaJIT's
      ** lj_err_arg does not, so match PUC here explicitly. */
      luaL_where(L, 2);
      luaL_error(L, "bad argument #2 to 'tonumber' (base out of range)");
    }
    while (lj_char_isspace((unsigned char)(*p))) p++;
    if (*p == '-') { p++; neg = 1; } else if (*p == '+') { p++; }
    /* 5.4: with an explicit base, a "0x" prefix is not allowed (strtoull
    ** would otherwise accept it for base 16). */
    if (base == 16 && p[0] == '0' && (p[1] | 0x20) == 'x') {
      setnilV(L->base-1-LJ_FR2);
      return FFH_RES(1);
    }
    if (lj_char_isalnum((unsigned char)(*p))) {
      ul = strtoull(p, &ep, base);
      if (p != ep) {
	while (ep < pend && lj_char_isspace((unsigned char)(*ep))) ep++;
	if (ep == pend) {
	  /* 5.4 (l_str2int with a base): the value wraps around modulo 2^64
	  ** and is always an integer. */
	  if (neg) ul = ~ul+1u;
	  lj_i64_tvstore(L, L->base-1-LJ_FR2, (int64_t)ul);
	  return FFH_RES(1);
	}
      }
    }
  }
  setnilV(L->base-1-LJ_FR2);
  return FFH_RES(1);
}

LJLIB_ASM(tostring)		LJLIB_REC(.)
{
  TValue *o = lj_lib_checkany(L, 1);
  cTValue *mo;
  L->top = o+1;  /* Only keep one argument. */
  if (!tvisnil(mo = lj_meta_lookup(L, o, MM_tostring))) {
    copyTV(L, L->base-1-LJ_FR2, mo);  /* Replace callable. */
    return FFH_TAILCALL;
  }
  lj_gc_check(L);
  setstrV(L, L->base-1-LJ_FR2, lj_strfmt_obj(L, L->base));
  return FFH_RES(1);
}

/* -- Base library: throw and catch errors -------------------------------- */

LJLIB_CF(error)
{
  int32_t level = lj_lib_optint(L, 2, 1);
  lua_settop(L, 1);
  /* 5.4: only actual strings get a position prefix (lua_isstring would also
  ** accept numbers, but error(42) must keep 42 as the error object). */
  if (lua_type(L, 1) == LUA_TSTRING && level > 0) {
    luaL_where(L, level);
    lua_pushvalue(L, 1);
    lua_concat(L, 2);
  }
  return lua_error(L);
}

LJLIB_ASM(pcall)		LJLIB_REC(.)
{
  if (L->ccallnest >= LJ_MAX_XLEVEL)  /* Fast-path C-call limit reached. */
    lj_err_cstack(L);
  lj_lib_checkany(L, 1);
  lj_lib_checkfunc(L, 2);  /* For xpcall only. */
  return FFH_UNREACHABLE;
}
LJLIB_ASM_(xpcall)		LJLIB_REC(.)

/* -- Base library: load Lua code ----------------------------------------- */

static int load_aux(lua_State *L, int status, int envarg)
{
  if (status == LUA_OK) {
    /*
    ** Set environment table for top-level function.
    ** Don't do this for non-native bytecode, which returns a prototype.
    */
    if (envarg > 0 && tvisfunc(L->top-1)) {
      GCfunc *fn = funcV(L->top-1);
      cTValue *ev = L->base+envarg-1;
      /* 5.4: any value is a valid _ENV (PUC stores it as the 1st upvalue).
      ** The table cache fn->l.env is NULL for a non-table value; the
      ** interpreter and recorder then use the generic index path. */
      lj_func_setenvv(fn, ev);
      if (tvisgcv(ev))
	lj_gc_barrier(L, fn, ev);
      /* 5.4: _ENV reads/writes inside the chunk are the GGET/GSET special
      ** case on the interned key (VM and recorder); the value itself must
      ** not carry an "_ENV" entry (PUC: _G._ENV == nil, pairs(_G) has none). */
    }
    return 1;
  } else {
    setnilV(L->top-2);
    return 2;
  }
}

LJLIB_CF(loadfile)
{
  GCstr *fname = lj_lib_optstr(L, 1);
  GCstr *mode = lj_lib_optstr(L, 2);
  int envidx = (L->base+2 < L->top) ? 3 : 0;  /* explicit env arg? */
  int status;
  lua_settop(L, 3);  /* Ensure env arg exists. */
  status = luaL_loadfilex(L, fname ? strdata(fname) : NULL,
			  mode ? strdata(mode) : NULL);
  return load_aux(L, status, envidx);
}

static const char *reader_func(lua_State *L, void *ud, size_t *size)
{
  UNUSED(ud);
  luaL_checkstack(L, 2, "too many nested functions");
  copyTV(L, L->top++, L->base);
  lua_call(L, 0, 1);  /* Call user-supplied function. */
  L->top--;
  if (tvisnil(L->top)) {
    *size = 0;
    return NULL;
  } else if (tvisstr(L->top) || tvisnumber(L->top)) {
    copyTV(L, L->base+4, L->top);  /* Anchor string in reserved stack slot. */
    return lua_tolstring(L, 5, size);
  } else {
    lj_err_caller(L, LJ_ERR_RDRSTR);
    return NULL;
  }
}

LJLIB_CF(load)
{
  GCstr *name = lj_lib_optstr(L, 2);
  GCstr *mode = lj_lib_optstr(L, 3);
  int status;
  if (L->base < L->top &&
      (tvisstr(L->base) || tvisnumber(L->base) || tvisbuf(L->base))) {
    const char *s;
    MSize len;
    if (tvisbuf(L->base)) {
      SBufExt *sbx = bufV(L->base);
      s = sbx->r;
      len = sbufxlen(sbx);
      if (!name) name = &G(L)->strempty;  /* Buffers are not NUL-terminated. */
    } else {
      GCstr *str = lj_lib_checkstr(L, 1);
      s = strdata(str);
      len = str->len;
    }
    int envidx = (L->base+3 < L->top) ? 4 : 0;  /* explicit env arg? */
    lua_settop(L, 4);  /* Ensure env arg exists. */
    status = luaL_loadbufferx(L, s, len, name ? strdata(name) : s,
			      mode ? strdata(mode) : NULL);
    return load_aux(L, status, envidx);
  } else {
    lj_lib_checkfunc(L, 1);
    int envidx = (L->base+3 < L->top) ? 4 : 0;  /* explicit env arg? */
    lua_settop(L, 5);  /* Reserve a slot for the string from the reader. */
    status = lua_loadx(L, reader_func, NULL, name ? strdata(name) : "=(load)",
		       mode ? strdata(mode) : NULL);
    return load_aux(L, status, envidx);
  }
}

LJLIB_CF(loadstring)
{
  return lj_cf_load(L);
}

LJLIB_CF(dofile)
{
  GCstr *fname = lj_lib_optstr(L, 1);
  setnilV(L->top);
  L->top = L->base+1;
  if (luaL_loadfile(L, fname ? strdata(fname) : NULL) != LUA_OK)
    lua_error(L);
  lua_call(L, 0, LUA_MULTRET);
  return (int)(L->top - L->base) - 1;
}

/* -- Base library: GC control -------------------------------------------- */

LJLIB_CF(gcinfo)
{
  setintV(L->top++, (int32_t)(G(L)->gc.total >> 10));
  return 1;
}

LJLIB_CF(collectgarbage)
{
  int opt = lj_lib_checkopt(L, 1, LUA_GCCOLLECT,  /* ORDER LUA_GC* */
    "\4stop\7restart\7collect\5count\1\377\4step\10setpause\12setstepmul\1\377\11isrunning\x0cgenerational\x0bincremental");
  int32_t data = lj_lib_optint(L, 2, 0);
  if (opt == LUA_GCCOUNT) {
    setnumV(L->top, (lua_Number)G(L)->gc.total/1024.0);
  } else {
    int res = lua_gc(L, opt, data);
    if (opt == LUA_GCSTEP || opt == LUA_GCISRUNNING) {
      setboolV(L->top, res);
    } else if (opt == LUA_GCGEN || opt == LUA_GCINC) {
      /* 5.4 collectgarbage returns the previous mode as a string. */
      setstrV(L, L->top, res == LUA_GCGEN ?
	      lj_str_newlit(L, "generational") : lj_str_newlit(L, "incremental"));
    } else {
      setintV(L->top, res);
    }
  }
  L->top++;
  return 1;
}

/* -- Base library: miscellaneous functions ------------------------------- */

LJLIB_PUSH(top-2)  /* Upvalue holds weak table. */
LJLIB_CF(newproxy)
{
  lua_settop(L, 1);
  lua_newuserdata(L, 0);
  if (lua_toboolean(L, 1) == 0) {  /* newproxy(): without metatable. */
    return 1;
  } else if (lua_isboolean(L, 1)) {  /* newproxy(true): with metatable. */
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_pushboolean(L, 1);
    lua_rawset(L, lua_upvalueindex(1));  /* Remember mt in weak table. */
  } else {  /* newproxy(proxy): inherit metatable. */
    int validproxy = 0;
    if (lua_getmetatable(L, 1)) {
      lua_rawget(L, lua_upvalueindex(1));
      validproxy = lua_toboolean(L, -1);
      lua_pop(L, 1);
    }
    if (!validproxy)
      lj_err_arg(L, 1, LJ_ERR_NOPROXY);
    lua_getmetatable(L, 1);
  }
  lua_setmetatable(L, 2);
  return 1;
}

LJLIB_PUSH("tostring")
LJLIB_CF(print)
{
  ptrdiff_t i, nargs = L->top - L->base;
  cTValue *tv = lj_tab_getstr(tabref(L->env), strV(lj_lib_upvalue(L, 1)));
  int shortcut;
  if (tv && !tvisnil(tv)) {
    copyTV(L, L->top++, tv);
  } else {
    setstrV(L, L->top++, strV(lj_lib_upvalue(L, 1)));
    lua_gettable(L, LUA_GLOBALSINDEX);
    tv = L->top-1;
  }
  shortcut = (tvisfunc(tv) && funcV(tv)->c.ffid == FF_tostring) &&
	     !gcrefu(basemt_it(G(L), LJ_TNUMX));
  for (i = 0; i < nargs; i++) {
    cTValue *o = &L->base[i];
    const char *str;
    size_t size;
    MSize len;
    if (shortcut && (str = lj_strfmt_wstrnum(L, o, &len)) != NULL) {
      size = len;
    } else {
      copyTV(L, L->top+1, o);
      copyTV(L, L->top, L->top-1);
      L->top += 2;
      lua_call(L, 1, 1);
      str = lua_tolstring(L, -1, &size);
      if (!str)
	lj_err_caller(L, LJ_ERR_PRTOSTR);
      L->top--;
    }
    if (i)
      putchar('\t');
    fwrite(str, 1, size, stdout);
  }
  putchar('\n');
  fflush(stdout);  /* PUC 5.4 lua_writeline flushes each line */
  return 0;
}

LJLIB_PUSH(top-3)
LJLIB_SET(_VERSION)

/* -- Base library: warnings ---------------------------------------------- */

/* Lua 5.4 warn(): all arguments must be strings (at least one); the parts are
** emitted with tocont=1 except the last, via the default emitter (a Lua
** replacement of `warn` is not involved in the C API path). */
LJLIB_CF(warn)
{
  int n = (int)(L->top - L->base);
  int i;
  luaL_checkstring(L, 1);
  for (i = 2; i <= n; i++)
    luaL_checkstring(L, i);
  for (i = 1; i < n; i++)
    lua_warning(L, lua_tostring(L, i), 1);
  lua_warning(L, lua_tostring(L, n), 0);
  return 0;
}

#include "lj_libdef.h"

/* -- Coroutine library --------------------------------------------------- */

#define LJLIB_MODULE_coroutine

LJLIB_CF(coroutine_status)
{
  const char *s;
  lua_State *co;
  if (!(L->top > L->base && tvisthread(L->base)))
    lj_err_arg(L, 1, LJ_ERR_NOCORO);
  co = threadV(L->base);
  if (co == L) s = "running";
  else if (co->status == LUA_YIELD) s = "suspended";
  else if (co->status != LUA_OK) s = "dead";
  else if (co->base > tvref(co->stack)+1+LJ_FR2) s = "normal";
  else if (co->top == co->base) s = "dead";
  else s = "suspended";
  lua_pushstring(L, s);
  return 1;
}

LJLIB_CF(coroutine_close)
{
  lua_State *co;
  const char *s;
  if (!(L->top > L->base && tvisthread(L->base)))
    lj_err_argtype(L, 1, "thread");
  co = threadV(L->base);
  if (co == L) s = "running";
  else if (co->status == LUA_YIELD) s = "suspended";
  else if (co->status != LUA_OK) s = "dead";
  else if (co->base > tvref(co->stack)+1+LJ_FR2) s = "normal";
  else if (co->top == co->base) s = "dead";
  else s = "suspended";
  if (strcmp(s, "suspended") == 0 || (strcmp(s, "dead") == 0 && co->status != LUA_OK)) {
    /* 5.4: close a suspended coroutine, or one that died with an error (its
    ** frames are still on its stack): run the pending __close handlers with
    ** nil or the error object, then reset the coroutine. An error inside a
    ** __close replaces the error object (false, err). */
    TValue *eslot;
    int st, nres;
    lj_state_checkstack(co, LUA_MINSTACK);
    eslot = co->top++;  /* Anchor the error object on the coroutine's stack. */
    if (co->status != LUA_OK && co->status != LUA_YIELD && co->top-1 > co->base)
      copyTV(co, eslot, eslot-1);
    else
      setnilV(eslot);
    co->status = LUA_OK;
    st = lj_meta_tbccloseall(co, tvref(co->stack), eslot);
    eslot = co->top-1;  /* The stack may have been reallocated. */
    if (st != LUA_OK || !tvisnil(eslot)) {
      setboolV(L->top++, 0);
      copyTV(L, L->top++, eslot);
      nres = 2;
    } else {
      setboolV(L->top++, 1);
      nres = 1;
    }
    lj_func_closeuv(co, tvref(co->stack));
    co->status = LUA_OK;
    co->base = co->top = tvref(co->stack) + 1 + LJ_FR2;
    co->cframe = NULL;
    return nres;
  }
  if (strcmp(s, "dead") == 0) {  /* Finished without error. */
    setboolV(L->top++, 1);
    return 1;
  }
  lj_err_callermsg(L, s[0] == 'r' ? "cannot close a running coroutine" :
		       "cannot close a normal coroutine");
  return 0;
}

LJLIB_CF(coroutine_running)
{
  /* Lua 5.4: the running coroutine plus a boolean (true for the main one). */
  int ismain = lua_pushthread(L);
  setboolV(L->top++, ismain);
  return 2;
}

LJLIB_CF(coroutine_isyieldable)
{
  setboolV(L->top++, cframe_canyield(L->cframe));
  return 1;
}

LJLIB_CF(coroutine_create)
{
  lua_State *L1;
  if (!(L->base < L->top && tvisfunc(L->base)))
    lj_err_argt(L, 1, LUA_TFUNCTION);
  L1 = lua_newthread(L);
  setfuncV(L, L1->top++, funcV(L->base));
  return 1;
}

LJLIB_ASM(coroutine_yield)
{
  /* 5.4 raises this without a source location (PUC lua_yieldk wording):
  ** "across a C-call boundary" inside a coroutine, "outside a coroutine"
  ** only on the main thread. */
  lj_err_msg(L, L != mainthread(G(L)) ? LJ_ERR_CYIELDK : LJ_ERR_CYIELD);
  return FFH_UNREACHABLE;
}

static int ffh_resume(lua_State *L, lua_State *co, int wrap)
{
  if (co->cframe != NULL || co->status > LUA_YIELD ||
      (co->status == LUA_OK && co->top == co->base)) {
    /* 5.4 wording: a running or normal coroutine is "non-suspended". */
    ErrMsg em = co->cframe ? LJ_ERR_COSUSP : LJ_ERR_CODEAD;
    if (wrap) lj_err_caller(L, em);
    setboolV(L->base-1-LJ_FR2, 0);
    setstrV(L, L->base-LJ_FR2, lj_err_str(L, em));
    return FFH_RES(2);
  }
  if (lj_state_cpgrowstack(co, (MSize)(L->top - L->base)) != LUA_OK) {
    cTValue *msg = --co->top;
    lj_err_callermsg(L, strVdata(msg));
  }
  return FFH_RETRY;
}

LJLIB_ASM(coroutine_resume)
{
  if (!(L->top > L->base && tvisthread(L->base)))
    lj_err_argtype(L, 1, "thread");
  return ffh_resume(L, threadV(L->base), 0);
}

LJLIB_NOREG LJLIB_ASM(coroutine_wrap_aux)
{
  return ffh_resume(L, threadV(lj_lib_upvalue(L, 1)), 1);
}

/* Inline declarations. */
LJ_ASMF void lj_ff_coroutine_wrap_aux(void);
#if !(LJ_TARGET_MIPS && defined(ljamalg_c))
LJ_FUNCA_NORET void LJ_FASTCALL lj_ffh_coroutine_wrap_err(lua_State *L,
							  lua_State *co);
#endif

/* Error handler, called from assembler VM. */
void LJ_FASTCALL lj_ffh_coroutine_wrap_err(lua_State *L, lua_State *co)
{
  if (co->tbcn > 0) {  /* 5.4: an error in a wrapped coroutine closes it. */
    co->status = LUA_OK;
    lj_meta_tbccloseall(co, tvref(co->stack), co->top-1);
    co->status = LUA_ERRRUN;
  }
  co->top--; copyTV(L, L->top, co->top); L->top++;
  if (tvisstr(L->top-1))
    lj_err_callermsg(L, strVdata(L->top-1));
  else
    lj_err_run(L);
}

/* Forward declaration. */
static void setpc_wrap_aux(lua_State *L, GCfunc *fn);

LJLIB_CF(coroutine_wrap)
{
  GCfunc *fn;
  lj_cf_coroutine_create(L);
  fn = lj_lib_pushcc(L, lj_ffh_coroutine_wrap_aux, FF_coroutine_wrap_aux, 1);
  setpc_wrap_aux(L, fn);
  return 1;
}

#include "lj_libdef.h"

/* PUC exposes coroutine as its own opener. In this fork the coroutine table
** is installed by luaopen_base; this entry returns that table. */
LUALIB_API int luaopen_coroutine(lua_State *L)
{
  lua_getglobal(L, LUA_COLIBNAME);
  if (!lua_istable(L, -1)) {
    /* Not open yet: register it through luaopen_base (the coroutine library
    ** lives there) and drop whatever that opener left on the stack. */
    int top;
    lua_pop(L, 1);
    top = lua_gettop(L);
    luaopen_base(L);
    lua_settop(L, top);
    lua_getglobal(L, LUA_COLIBNAME);
  }
  return 1;
}

/* Fix the PC of wrap_aux. Really ugly workaround. */
static void setpc_wrap_aux(lua_State *L, GCfunc *fn)
{
  setmref(fn->c.pc, &L2GG(L)->bcff[lj_lib_init_coroutine[1]+2]);
}

/* ------------------------------------------------------------------------ */

static void newproxy_weaktable(lua_State *L)
{
  /* NOBARRIER: The table is new (marked white). */
  GCtab *t = lj_tab_new(L, 0, 1);
  settabV(L, L->top++, t);
  setgcref(t->metatable, obj2gco(t));
  setstrV(L, lj_tab_setstr(L, t, lj_str_newlit(L, "__mode")),
	    lj_str_newlit(L, "kv"));
  t->nomm = (uint8_t)(~(1u<<MM_mode));
}

LUALIB_API int luaopen_base(lua_State *L)
{
  /* NOBARRIER: Table and value are the same. */
  GCtab *env = tabref(L->env);
  settabV(L, lj_tab_setstr(L, env, lj_str_newlit(L, "_G")), env);
  /* Lua 5.4: the chunk environment is _ENV. LuaJIT resolves globals through
  ** the function env; the VM special-cases the interned "_ENV" key so reads
  ** yield the env and writes retarget it (function scope, see docs).
  ** The interned string itself is created at state creation (lj_state.c), so
  ** a state without the base library can parse and record global accesses.
  ** No _G._ENV entry: PUC's _ENV is an upvalue, not a global. */
  lua_pushliteral(L, LUA_VERSION);  /* top-3. */
  newproxy_weaktable(L);  /* top-2. */
  LJ_LIB_REG(L, "_G", base);
  LJ_LIB_REG(L, LUA_COLIBNAME, coroutine);
  /* 5.4 dofile may yield: the C call boundary of the stock implementation
  ** forbids it, so install a Lua wrapper that calls the loaded chunk from
  ** Lua (loadfile/error semantics are unchanged for normal use). */
  {
    static const char dofilesrc[] =
      "local loadfile = loadfile\n"
      "return function(name)\n"
      "  local f, e = loadfile(name)\n"
      "  if not f then error(e, 0) end\n"
      "  return f()\n"
      "end\n";
    GCstr *key = lj_str_newlit(L, "dofile");
    luaL_loadstring(L, dofilesrc);
    lua_call(L, 0, 1);
    setfuncV(L, lj_tab_setstr(L, env, key), funcV(L->top-1));
    L->top--;
  }
  /* 5.4 warnings: the auxlib default is OFF (luaL_newstate); only set the
  ** registry state if it was not configured yet. The standalone interpreter
  ** leaves this off, like PUC without -W. */
  lua_pushliteral(L, "_LJ_WARN_STATE");
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_pushliteral(L, "_LJ_WARN_STATE");
    lua_pushinteger(L, 0);
    lua_rawset(L, LUA_REGISTRYINDEX);
  } else {
    lua_pop(L, 1);
  }
  return 2;
}

