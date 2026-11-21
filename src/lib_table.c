/*
** Table library.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lib_table_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <limits.h>

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_tab.h"
#include "lj_meta.h"
#include "lj_ff.h"
#include "lj_lib.h"
#include "lj_strfmt.h"
#include "lj_strscan.h"
#include "lj_i64.h"

/* ------------------------------------------------------------------------ */

typedef size_t lj_tab_Unsigned;  /* Unsigned counterpart of lua_Integer. */
#define LJ_TAB_MAXINT ((lua_Integer)(~(lj_tab_Unsigned)0 >> 1))

#define LJLIB_MODULE_table

/* PUC 5.4.9 ltablib.c table-like rules: the operations an object must
** define to stand in for a table (some functions only need some of them). */
#define TAB_R	1		/* read */
#define TAB_W	2		/* write */
#define TAB_L	4		/* length */
#define TAB_RW	(TAB_R | TAB_W)		/* read/write */

/*
** PUC-mirror checktab (5.4.9 ltablib.c): the argument must be a table, or a
** value whose metatable carries the required metamethods as non-nil raw
** fields (a field set to false still counts as present, as in PUC).
** Returns the GCtab when the argument is a plain table with none of the
** requested metamethods (the raw-access fast path is correct), NULL when the
** generic lua_geti/lua_seti/luaL_len path must be used (a table with the
** relevant metamethods or a table-like value). Otherwise raises the standard
** "table expected, got ..." error.
*/
static GCtab *tab_checktab(lua_State *L, int arg, int what)
{
  cTValue *o = L->base + (arg - 1);
  GCtab *t, *mt;
  if (!tvistab(o)) {
    int n = 1;  /* Number of elements to pop. */
    if (lua_getmetatable(L, arg) &&  /* Must have a metatable. */
	(!(what & TAB_R) ||
	 (lua_pushlstring(L, "__index", 7),
	  lua_rawget(L, -++n) != LUA_TNIL)) &&
	(!(what & TAB_W) ||
	 (lua_pushlstring(L, "__newindex", 10),
	  lua_rawget(L, -++n) != LUA_TNIL)) &&
	(!(what & TAB_L) ||
	 (lua_pushlstring(L, "__len", 5),
	  lua_rawget(L, -++n) != LUA_TNIL)))
      lua_pop(L, n);  /* Pop the metatable and the tested metamethods. */
    else
      lj_err_argt(L, arg, LUA_TTABLE);  /* Force an error. */
    return NULL;  /* Generic path. */
  }
  t = tabV(o);
  mt = tabref(t->metatable);  /* NULL when the table has no metatable. */
  if (mt != NULL &&
      (((what & TAB_R) && lj_meta_fast(L, mt, MM_index)) ||
       ((what & TAB_W) && lj_meta_fast(L, mt, MM_newindex)) ||
       ((what & TAB_L) && lj_meta_fast(L, mt, MM_len))))
    return NULL;  /* Generic path: metamethod-aware access. */
  return t;  /* Fast path: raw access is correct. */
}

/* The Lua 5.1 iteration and size helpers: pairs/#/table.unpack cover them in
** 5.4, so they are not part of the default build. Only with
** -DLUAJIT_ENABLE_51COMPAT. genlibbc.lua scans the Lua library bodies without
** a preprocessor, so buildvm_libbc.h keeps their bytecode in both builds. */
#if LJ_51COMPAT
LJLIB_LUA(table_foreachi) /*
  function(t, f)
    CHECK_tab(t)
    CHECK_func(f)
    for i=1,#t do
      local r = f(i, t[i])
      if r ~= nil then return r end
    end
  end
*/

LJLIB_LUA(table_foreach) /*
  function(t, f)
    CHECK_tab(t)
    CHECK_func(f)
    for k, v in PAIRS(t) do
      local r = f(k, v)
      if r ~= nil then return r end
    end
  end
*/

LJLIB_LUA(table_getn) /*
  function(t)
    CHECK_tab(t)
    return #t
  end
*/

LJLIB_CF(table_maxn)
{
  GCtab *t = lj_lib_checktab(L, 1);
  TValue *array = tvref(t->array);
  Node *node;
  lua_Number m = 0;
  ptrdiff_t i;
  for (i = (ptrdiff_t)t->asize - 1; i >= 0; i--)
    if (!tvisnil(&array[i])) {
      m = (lua_Number)(int32_t)i;
      break;
    }
  node = noderef(t->node);
  for (i = (ptrdiff_t)t->hmask; i >= 0; i--)
    if (!tvisnil(&node[i].val) && tvisnumber(&node[i].key)) {
      lua_Number n = numberVnum(&node[i].key);
      if (n > m) m = n;
    }
  setnumV(L->top-1, m);
  return 1;
}
#endif

LJLIB_CF(table_insert)		LJLIB_REC(.)
{
  GCtab *t = tab_checktab(L, 1, TAB_RW | TAB_L);
  lua_Integer pos, e;
  int nargs = (int)(L->top - L->base);
  if (t)
    e = (lua_Integer)lj_tab_len(t) + 1;  /* Plain table: no __len, no wrap. */
  else
    e = luaL_intop(+, luaL_len(L, 1), 1);  /* PUC: __len, wraps on overflow. */
  if (nargs == 2) {
    pos = e;  /* Insert new element at the end. */
  } else if (nargs == 3) {
    /* PUC: 2nd argument is the position; a non-integral float is an error.
    ** Check whether 'pos' is in [1, e]. */
    pos = luaL_checkinteger(L, 2);
    if (!((lj_tab_Unsigned)pos - 1u < (lj_tab_Unsigned)e))
      lj_err_arg(L, 2, LJ_ERR_TABINSPOS);
  } else {
    lj_err_caller(L, LJ_ERR_TABINS);
  }
  if (t) {
    int32_t i, n = (int32_t)pos, el = (int32_t)e;
    /* The bound check passed: for a plain table e <= #t+1 < 2^24 and
    ** 1 <= pos <= e, so both fit in int32. */
    /* NOBARRIER: This just moves existing elements around. */
    for (i = el; i > n; i--) {
      /* The set may invalidate the get pointer, so need to do it first! */
      TValue *dst = lj_tab_setint(L, t, i);
      cTValue *src = lj_tab_getint(t, i-1);
      if (src) {
	copyTV(L, dst, src);
      } else {
	setnilV(dst);
      }
    }
    {
      TValue *dst = lj_tab_setint(L, t, n);
      copyTV(L, dst, L->top-1);  /* Set new value. */
      lj_gc_barriert(L, t, dst);
    }
    return 0;
  }
  /* Generic path (PUC tinsert): shift and store through the API so
  ** __index/__newindex are honoured. */
  {
    lua_Integer i;
    for (i = e; i > pos; i--) {
      lua_geti(L, 1, i - 1);
      lua_seti(L, 1, i);  /* t[i] = t[i - 1] */
    }
    lua_seti(L, 1, pos);  /* t[pos] = v */
  }
  return 0;
}

LJLIB_CF(table_remove)
{
  GCtab *t = tab_checktab(L, 1, TAB_RW | TAB_L);
  if (!t) {
    /* Generic path (PUC tremove): element access through the API so
    ** __index/__newindex are honoured; #t via __len. */
    lua_Integer size = luaL_len(L, 1);
    lua_Integer pos = luaL_optinteger(L, 2, size);  /* PUC: nil is absent */
    if (pos != size &&
	((lj_tab_Unsigned)pos - 1u > (lj_tab_Unsigned)size))
      lj_err_arg(L, 2, LJ_ERR_TABINSPOS);
    lua_geti(L, 1, pos);  /* result = t[pos] */
    for (; pos < size; pos++) {
      lua_geti(L, 1, pos + 1);
      lua_seti(L, 1, pos);  /* t[pos] = t[pos + 1] */
    }
    lua_pushnil(L);
    lua_seti(L, 1, pos);  /* remove entry t[pos] */
    return 1;
  }
  lua_Integer len = luaL_len(L, 1);
  lua_Integer pos = luaL_optinteger(L, 2, len);  /* PUC: nil is absent */
  /* 5.4 tremove: a given pos is validated as (unsigned)pos - 1 <= (unsigned)
  ** size, so pos = size + 1 is allowed (nothing to shift, t[pos] is nil) and
  ** pos 0 or a negative pos with a non-empty table is "position out of
  ** bounds". pos == size skips the check, which also lets an empty table
  ** remove t[0]: pos = size = 0. */
  if (pos != len && ((lj_tab_Unsigned)pos - 1u > (lj_tab_Unsigned)len))
    lj_err_arg(L, 2, LJ_ERR_TABINSPOS);
  {
    TValue old;
    int haveold = 0;
    /* The index accesses are raw, as in the previous Lua emulation (CHECK_tab
    ** made its t[...] accesses raw); __len is still honoured through
    ** luaL_len, as before. */
    if ((int64_t)(int32_t)pos == pos) {
      cTValue *src = lj_tab_getint(t, (int32_t)pos);
      if (src) { copyTV(L, &old, src); haveold = 1; }
    }
    if ((int64_t)(int32_t)len == len && (int64_t)(int32_t)pos == pos) {
      int32_t p = (int32_t)pos, n = (int32_t)len;
      int32_t i;
      for (i = p; i < n; i++) {
	TValue *dst = lj_tab_setint(L, t, i);
	cTValue *src = lj_tab_getint(t, i + 1);
	if (src) copyTV(L, dst, src); else setnilV(dst);
      }
      /* PUC clears t[pos] with pos at its value after the shift loop: for
      ** pos <= size that is t[size], for pos = size + 1 it is t[size + 1]. */
      setnilV(lj_tab_setint(L, t, p > n ? p : n));
    }
    if (haveold) { copyTV(L, L->top, &old); L->top++; }
    else setnilV(L->top++);
    return 1;
  }
}

/* A 5.4 integer argument (PUC luaL_optinteger): exact, so a bound outside
** int32 stays what it is; a non-integral float is an error like in PUC. */
static int64_t tab_concat_int64(lua_State *L, int narg, int64_t def)
{
  TValue *o = L->base + narg-1;
  int64_t v;
  if (!(o < L->top) || tvisnil(o)) return def;
  if (!lj_strscan_numberobj64(L, o)) lj_err_argt(L, narg, LUA_TNUMBER);
  if (lj_i64_getint(o, &v)) return v;  /* int32, widened or boxed */
  if (lj_i64_numtoint(numV(o), &v)) return v;
  lj_err_arg(L, narg, LJ_ERR_NUMNOINT);
  return def;  /* unreachable */
}

LJLIB_CF(table_concat)		LJLIB_REC(.)
{
  GCtab *t = tab_checktab(L, 1, TAB_R | TAB_L);
  /* PUC tconcat: aux_getn calls __len first, before the separator and the
  ** bounds are checked, and also when an explicit end is given. For a plain
  ** table the raw length is not observable, so it is only taken when no end
  ** is given. */
  int64_t len = t ? 0 : (int64_t)luaL_len(L, 1);
  GCstr *sep = lj_lib_optstr(L, 2);
  int64_t i = tab_concat_int64(L, 3, 1);
  int64_t e = (L->base+3 < L->top && !tvisnil(L->base+3)) ?
	      tab_concat_int64(L, 4, 0) :
	      (t ? (int64_t)lj_tab_len(t) : len);
  SBuf *sb;
  SBuf *sbx;
  int64_t fail = 0;
  if (!t) {
    /* Generic path (PUC tconcat): element reads through lua_geti so __index
    ** is honoured. The result is built in a luaL_Buffer of this call, as in
    ** PUC: an __index may run any code, including code that uses or frees
    ** the global temp buffer (string.format, '..', a nested table.concat, a
    ** collection), so nothing may stay in that buffer across lua_geti. */
    luaL_Buffer b;
    MSize seplen = sep ? sep->len : 0;
    lua_settop(L, 2);  /* The separator stays anchored in slot 2. */
    luaL_buffinit(L, &b);
    if (i <= e) {
      int64_t j;
      for (j = i; ; j++) {
	cTValue *o;
	lua_geti(L, 1, j);
	o = L->top - 1;
	if (LJ_UNLIKELY(!(tvisstr(o) || tvisnumber(o) || tvisi64(o)))) {
	  GCstr *sidx = lj_strfmt_i64(L, j);
	  lj_err_callerv(L, LJ_ERR_TABCAT,
			 lj_obj_itypename[itypemap(o)], strdata(sidx));
	}
	if (tvisstr(o) && strV(o)->len <= b.size - b.n) {
	  /* Fits: copy it straight in (what luaL_addvalue does, minus the
	  ** calls). The value is still on the stack while it is copied. */
	  memcpy(b.b + b.n, strVdata(o), strV(o)->len);
	  b.n += strV(o)->len;
	  L->top--;
	} else {
	  luaL_addvalue(&b);
	}
	if (j == e) break;
	if (seplen) {
	  if (seplen <= b.size - b.n) {
	    memcpy(b.b + b.n, strdata(sep), seplen);
	    b.n += seplen;
	  } else {
	    luaL_addlstring(&b, strdata(sep), seplen);
	  }
	}
      }
    }
    luaL_pushresult(&b);
    return 1;
  }
  sb = lj_buf_tmp_(L);
  if (i >= -0x7fffffff-1 && i <= 0x7fffffff &&
      e >= -0x7fffffff-1 && e <= 0x7fffffff) {
    sbx = lj_buf_puttab(sb, t, sep, (int32_t)i, (int32_t)e);
    if (LJ_UNLIKELY(!sbx)) fail = (int32_t)(intptr_t)sb->w;
  } else {
    sbx = lj_buf_puttab64(L, sb, t, sep, i, e, &fail);
  }
  if (LJ_UNLIKELY(!sbx)) {  /* Error: bad element type at index 'fail'. */
    TValue k;
    cTValue *o;
    GCstr *sidx = lj_strfmt_i64(L, fail);  /* 5.4 lua_Integer, not int32 */
    lj_i64_tvstore(L, &k, fail);
    o = lj_tab_get(L, t, &k);
    lj_err_callerv(L, LJ_ERR_TABCAT,
		   lj_obj_itypename[o ? itypemap(o) : ~LJ_TNIL], strdata(sidx));
  }
  setstrV(L, L->top-1, lj_buf_str(L, sbx));
  lj_gc_check(L);
  return 1;
}

/* ------------------------------------------------------------------------ */

/* Sort element access: 'mm' selects the metamethod-aware API (proxy and
** table-like tables honour __index/__newindex); for plain tables the raw
** access is equivalent and kept as the fast path. */
static int sort_geti(lua_State *L, int mm, int i)
{
  return mm ? lua_geti(L, 1, i) : lua_rawgeti(L, 1, i);
}

static void sort_seti(lua_State *L, int mm, int i)
{
  if (mm) lua_seti(L, 1, i); else lua_rawseti(L, 1, i);
}

static void set2(lua_State *L, int mm, int i, int j)
{
  sort_seti(L, mm, i);
  sort_seti(L, mm, j);
}

static int sort_comp(lua_State *L, int a, int b)
{
  if (!lua_isnil(L, 2)) {  /* function? */
    int res;
    lua_pushvalue(L, 2);
    lua_pushvalue(L, a-1);  /* -1 to compensate function */
    lua_pushvalue(L, b-2);  /* -2 to compensate function and `a' */
    lua_call(L, 2, 1);
    res = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return res;
  } else {  /* a < b? */
    return lua_lessthan(L, a, b);
  }
}

static void auxsort(lua_State *L, int l, int u, int mm)
{
  while (l < u) {  /* for tail recursion */
    int i, j;
    /* sort elements a[l], a[(l+u)/2] and a[u] */
    sort_geti(L, mm, l);
    sort_geti(L, mm, u);
    if (sort_comp(L, -1, -2))  /* a[u] < a[l]? */
      set2(L, mm, l, u);  /* swap a[l] - a[u] */
    else
      lua_pop(L, 2);
    if (u-l == 1) break;  /* only 2 elements */
    i = (l+u)/2;
    sort_geti(L, mm, i);
    sort_geti(L, mm, l);
    if (sort_comp(L, -2, -1)) {  /* a[i]<a[l]? */
      set2(L, mm, i, l);
    } else {
      lua_pop(L, 1);  /* remove a[l] */
      sort_geti(L, mm, u);
      if (sort_comp(L, -1, -2))  /* a[u]<a[i]? */
	set2(L, mm, i, u);
      else
	lua_pop(L, 2);
    }
    if (u-l == 2) break;  /* only 3 elements */
    sort_geti(L, mm, i);  /* Pivot */
    lua_pushvalue(L, -1);
    sort_geti(L, mm, u-1);
    set2(L, mm, i, u-1);
    /* a[l] <= P == a[u-1] <= a[u], only need to sort from l+1 to u-2 */
    i = l; j = u-1;
    for (;;) {  /* invariant: a[l..i] <= P <= a[j..u] */
      /* repeat ++i until a[i] >= P */
      while (sort_geti(L, mm, ++i), sort_comp(L, -1, -2)) {
	if (i>=u) lj_err_caller(L, LJ_ERR_TABSORT);
	lua_pop(L, 1);  /* remove a[i] */
      }
      /* repeat --j until a[j] <= P */
      while (sort_geti(L, mm, --j), sort_comp(L, -3, -1)) {
	if (j<=l) lj_err_caller(L, LJ_ERR_TABSORT);
	lua_pop(L, 1);  /* remove a[j] */
      }
      if (j<i) {
	lua_pop(L, 3);  /* pop pivot, a[i], a[j] */
	break;
      }
      set2(L, mm, i, j);
    }
    sort_geti(L, mm, u-1);
    sort_geti(L, mm, i);
    set2(L, mm, u-1, i);  /* swap pivot (a[u-1]) with a[i] */
    /* a[l..i-1] <= a[i] == P <= a[i+1..u] */
    /* adjust so that smaller half is in [j..i] and larger one in [l..u] */
    if (i-l < u-i) {
      j=l; i=i-1; l=i+2;
    } else {
      j=i+1; i=u; u=j-2;
    }
    auxsort(L, j, i, mm);  /* call recursively the smaller one */
  }  /* repeat the routine for the larger one */
}

LJLIB_CF(table_sort)
{
  GCtab *t = tab_checktab(L, 1, TAB_RW | TAB_L);
  {
    /* 5.4: length goes through luaL_len (__len honored); a huge result is
    ** PUC's "array too big", and n <= 1 sorts nothing. */
    lua_Integer len = luaL_len(L, 1);
    int32_t n = (int32_t)len;
    if (len > 1)
      luaL_argcheck(L, len < INT_MAX, 1, "array too big");
    if (n > 1) {
      lua_settop(L, 2);
      if (!tvisnil(L->base+1))
	lj_lib_checkfunc(L, 2);
      auxsort(L, 1, n, t == NULL);  /* mm: metamethod-aware access. */
    }
  }
  return 0;
}

LJLIB_PUSH("n")
LJLIB_CF(table_pack)
{
  TValue *array, *base = L->base;
  MSize i, n = (uint32_t)(L->top - base);
  GCtab *t = lj_tab_new(L, n ? n+1 : 0, 1);
  /* NOBARRIER: The table is new (marked white). */
  setintV(lj_tab_setstr(L, t, strV(lj_lib_upvalue(L, 1))), (int32_t)n);
  for (array = tvref(t->array) + 1, i = 0; i < n; i++)
    copyTV(L, &array[i], &base[i]);
  settabV(L, base, t);
  L->top = base+1;
  lj_gc_check(L);
  return 1;
}

/* -- Lua 5.4 additions (MISSION P5.3) ------------------------------------ */

/* Unsigned counterpart of lua_Integer (ptrdiff_t) for overflow-safe math. */


LJLIB_CF(table_move)
{
  lua_Integer f = luaL_checkinteger(L, 2);
  lua_Integer e = luaL_checkinteger(L, 3);
  lua_Integer t = luaL_checkinteger(L, 4);
  int tt = !lua_isnoneornil(L, 5) ? 5 : 1;  /* destination table */
  /* PUC checktab: source needs __index (TAB_R), destination __newindex
  ** (TAB_W); no length involved. Table-like values are accepted. */
  tab_checktab(L, 1, TAB_R);
  tab_checktab(L, tt, TAB_W);
  if (e >= f) {  /* otherwise, nothing to move */
    lua_Integer n, i;
    luaL_argcheck(L, f > 0 || e < LJ_TAB_MAXINT + f, 3,
		  "too many elements to move");
    n = e - f + 1;
    luaL_argcheck(L, t <= LJ_TAB_MAXINT - n + 1, 4,
		  "destination wrap around");
    if (t > e || t <= f || (tt != 1 && !lua_compare(L, 1, tt, LUA_OPEQ))) {
      for (i = 0; i < n; i++) {
	lua_geti(L, 1, f + i);
	lua_seti(L, tt, t + i);
      }
    } else {  /* overlapping ranges: move backwards */
      for (i = n - 1; i >= 0; i--) {
	lua_geti(L, 1, f + i);
	lua_seti(L, tt, t + i);
      }
    }
  }
  lua_pushvalue(L, tt);  /* return destination table */
  return 1;
}

LJLIB_CF(table_unpack)
{
  lj_tab_Unsigned n;
  lua_Integer i = luaL_optinteger(L, 2, 1);
  lua_Integer e = luaL_opt(L, luaL_checkinteger, 3, luaL_len(L, 1));
  if (i > e) return 0;  /* empty range */
  n = (lj_tab_Unsigned)e - i;  /* number of elements minus 1 */
  if (LJ_UNLIKELY(n >= (lj_tab_Unsigned)INT_MAX ||
		  !lua_checkstack(L, (int)(++n))))
    return luaL_error(L, "too many results to unpack");
  for (; i < e; i++)
    lua_geti(L, 1, i);
  lua_geti(L, 1, e);  /* push last element */
  return (int)n;
}

LJLIB_NOREG LJLIB_CF(table_new)		LJLIB_REC(.)
{
  int32_t a = lj_lib_checkint(L, 1);
  int32_t h = lj_lib_checkint(L, 2);
  lua_createtable(L, a, h);
  return 1;
}

LJLIB_NOREG LJLIB_CF(table_clear)	LJLIB_REC(.)
{
  lj_tab_clear(lj_lib_checktab(L, 1));
  return 0;
}

static int luaopen_table_new(lua_State *L)
{
  return lj_lib_postreg(L, lj_cf_table_new, FF_table_new, "new");
}

static int luaopen_table_clear(lua_State *L)
{
  return lj_lib_postreg(L, lj_cf_table_clear, FF_table_clear, "clear");
}

/* ------------------------------------------------------------------------ */

#include "lj_libdef.h"

LUALIB_API int luaopen_table(lua_State *L)
{
  LJ_LIB_REG(L, LUA_TABLIBNAME, table);
  lj_lib_prereg(L, LUA_TABLIBNAME ".new", luaopen_table_new, tabV(L->top-1));
  lj_lib_prereg(L, LUA_TABLIBNAME ".clear", luaopen_table_clear, tabV(L->top-1));
  return 1;
}

