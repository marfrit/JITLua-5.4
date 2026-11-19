/*
** Auxiliary library for the Lua/C API.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major parts taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define lib_aux_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"

#include "lj_obj.h"
#include "lj_err.h"
#include "lj_state.h"
#include "lj_trace.h"
#include "lj_lib.h"
#include "lj_vmevent.h"

#if LJ_TARGET_POSIX
#include <sys/wait.h>
#endif

/* -- I/O error handling -------------------------------------------------- */

LUALIB_API int luaL_fileresult(lua_State *L, int stat, const char *fname)
{
  if (stat) {
    setboolV(L->top++, 1);
    return 1;
  } else {
    int en = errno;  /* Lua API calls may change this value. */
    setnilV(L->top++);
    if (fname)
      lua_pushfstring(L, "%s: %s", fname, strerror(en));
    else
      lua_pushfstring(L, "%s", strerror(en));
    setintV(L->top++, en);
    lj_trace_abort(G(L));
    return 3;
  }
}

LUALIB_API int luaL_execresult(lua_State *L, int stat)
{
  if (stat != -1) {
#if LJ_TARGET_POSIX
    if (WIFSIGNALED(stat)) {
      stat = WTERMSIG(stat);
      setnilV(L->top++);
      lua_pushliteral(L, "signal");
    } else {
      if (WIFEXITED(stat))
	stat = WEXITSTATUS(stat);
      if (stat == 0)
	setboolV(L->top++, 1);
      else
	setnilV(L->top++);
      lua_pushliteral(L, "exit");
    }
#else
    if (stat == 0)
      setboolV(L->top++, 1);
    else
      setnilV(L->top++);
    lua_pushliteral(L, "exit");
#endif
    setintV(L->top++, stat);
    return 3;
  }
  return luaL_fileresult(L, 0, NULL);
}

/* -- Module registration ------------------------------------------------- */

LUALIB_API const char *luaL_findtable(lua_State *L, int idx,
				      const char *fname, int szhint)
{
  const char *e;
  lua_pushvalue(L, idx);
  do {
    e = strchr(fname, '.');
    if (e == NULL) e = fname + strlen(fname);
    lua_pushlstring(L, fname, (size_t)(e - fname));
    lua_rawget(L, -2);
    if (lua_isnil(L, -1)) {  /* no such field? */
      lua_pop(L, 1);  /* remove this nil */
      lua_createtable(L, 0, (*e == '.' ? 1 : szhint)); /* new table for field */
      lua_pushlstring(L, fname, (size_t)(e - fname));
      lua_pushvalue(L, -2);
      lua_settable(L, -4);  /* set new table into field */
    } else if (!lua_istable(L, -1)) {  /* field has a non-table value? */
      lua_pop(L, 2);  /* remove table and value */
      return fname;  /* return problematic part of the name */
    }
    lua_remove(L, -2);  /* remove previous table */
    fname = e + 1;
  } while (*e == '.');
  return NULL;
}

static int libsize(const luaL_Reg *l)
{
  int size = 0;
  for (; l && l->name; l++) size++;
  return size;
}

LUALIB_API void luaL_pushmodule(lua_State *L, const char *modname, int sizehint)
{
  luaL_findtable(L, LUA_REGISTRYINDEX, "_LOADED", 16);
  lua_getfield(L, -1, modname);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    if (luaL_findtable(L, LUA_GLOBALSINDEX, modname, sizehint) != NULL)
      lj_err_callerv(L, LJ_ERR_BADMODN, modname);
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, modname);  /* _LOADED[modname] = new table. */
  }
  lua_remove(L, -2);  /* Remove _LOADED table. */
}

LUALIB_API void luaL_openlib(lua_State *L, const char *libname,
			     const luaL_Reg *l, int nup)
{
  lj_lib_checkfpu(L);
  if (libname) {
    luaL_pushmodule(L, libname, libsize(l));
    lua_insert(L, -(nup + 1));  /* Move module table below upvalues. */
  }
  if (l)
    luaL_setfuncs(L, l, nup);
  else
    lua_pop(L, nup);  /* Remove upvalues. */
}

LUALIB_API void luaL_register(lua_State *L, const char *libname,
			      const luaL_Reg *l)
{
  luaL_openlib(L, libname, l, 0);
}

/* -- Lua 5.4 auxiliary library additions (MISSION P1.6) ------------------ */

LUALIB_API lua_Integer luaL_len(lua_State *L, int idx)
{
  lua_Integer l;
  int isnum;
  lua_len(L, idx);
  l = lua_tointegerx(L, -1, &isnum);
  if (!isnum)
    luaL_error(L, "object length is not an integer");
  lua_pop(L, 1);
  return l;
}

LUALIB_API int luaL_typeerror(lua_State *L, int arg, const char *tname)
{
  const char *typearg;
  if (luaL_getmetafield(L, arg, "__name") == LUA_TSTRING)
    typearg = lua_tostring(L, -1);
  else if (lua_type(L, arg) == LUA_TLIGHTUSERDATA)
    typearg = "light userdata";
  else
    typearg = luaL_typename(L, arg);
  lua_pushfstring(L, "%s expected, got %s", tname, typearg);
  return luaL_argerror(L, arg, lua_tostring(L, -1));
}

LUALIB_API const char *luaL_tolstring(lua_State *L, int idx, size_t *len)
{
  idx = lua_absindex(L, idx);
  if (luaL_callmeta(L, idx, "__tostring")) {
    if (!lua_isstring(L, -1))
      luaL_error(L, "'__tostring' must return a string");
  } else {
    switch (lua_type(L, idx)) {
    case LUA_TNUMBER:
    case LUA_TSTRING:
      lua_pushvalue(L, idx);
      break;
    case LUA_TBOOLEAN:
      lua_pushstring(L, lua_toboolean(L, idx) ? "true" : "false");
      break;
    case LUA_TNIL:
      lua_pushliteral(L, "nil");
      break;
    default: {
      int tt = luaL_getmetafield(L, idx, "__name");
      const char *kind = (tt == LUA_TSTRING) ? lua_tostring(L, -1) :
					     luaL_typename(L, idx);
      lua_pushfstring(L, "%s: %p", kind, lua_topointer(L, idx));
      if (tt != LUA_TNIL) lua_remove(L, -2);
      break;
    }
    }
  }
  return lua_tolstring(L, -1, len);
}

LUALIB_API void luaL_requiref(lua_State *L, const char *modname,
			      lua_CFunction openf, int glb)
{
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, modname);
  if (!lua_toboolean(L, -1)) {
    lua_pop(L, 1);
    lua_pushcfunction(L, openf);
    lua_pushstring(L, modname);
    lua_call(L, 1, 1);
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, modname);
  }
  lua_remove(L, -2);
  if (glb) {
    lua_pushvalue(L, -1);
    lua_setglobal(L, modname);
  }
}

LUALIB_API int luaL_getsubtable(lua_State *L, int idx, const char *fname)
{
  lua_getfield(L, idx, fname);
  if (lua_istable(L, -1))
    return 1;  /* table already there */
  lua_pop(L, 1);  /* remove previous result */
  idx = lua_absindex(L, idx);
  lua_newtable(L);
  lua_pushvalue(L, -1);  /* copy to be left on stack */
  lua_setfield(L, idx, fname);
  return 0;
}

LUALIB_API void luaL_setfuncs(lua_State *L, const luaL_Reg *l, int nup)
{
  luaL_checkstack(L, nup, "too many upvalues");
  for (; l->name; l++) {
    int i;
    for (i = 0; i < nup; i++)  /* Copy upvalues to the top. */
      lua_pushvalue(L, -nup);
    lua_pushcclosure(L, l->func, nup);
    lua_setfield(L, -(nup + 2), l->name);
  }
  lua_pop(L, nup);  /* Remove upvalues. */
}

LUALIB_API void luaL_addgsub(luaL_Buffer *b, const char *s,
			     const char *p, const char *r)
{
  size_t l = strlen(p);
  const char *wild;
  if (l == 0) {  /* Avoid PUC's infinite loop on an empty pattern. */
    luaL_addstring(b, s);
    return;
  }
  while ((wild = strstr(s, p)) != NULL) {
    luaL_addlstring(b, s, (size_t)(wild - s));  /* push prefix */
    luaL_addstring(b, r);  /* push replacement in place of pattern */
    s = wild + l;  /* continue after `p' */
  }
  luaL_addstring(b, s);  /* push last suffix */
}

LUALIB_API const char *luaL_gsub(lua_State *L, const char *s,
				 const char *p, const char *r)
{
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addgsub(&b, s, p, r);
  luaL_pushresult(&b);
  return lua_tostring(L, -1);
}

/* -- Buffer handling ----------------------------------------------------- */

/* userdata to box arbitrary data (PUC 5.4 luaL_Buffer layout and growth) */
typedef struct UBox {
  void *box;
  size_t bsize;
} UBox;

static void *resizebox(lua_State *L, int idx, size_t newsize)
{
  void *ud;
  lua_Alloc allocf = lua_getallocf(L, &ud);
  UBox *box = (UBox *)lua_touserdata(L, idx);
  void *temp = allocf(ud, box->box, box->bsize, newsize);
  if (temp == NULL && newsize > 0) {  /* allocation error? */
    lua_pushliteral(L, "not enough memory");
    lua_error(L);
  }
  box->box = temp;
  box->bsize = newsize;
  return temp;
}

static int boxgc(lua_State *L)
{
  resizebox(L, 1, 0);
  return 0;
}

static const luaL_Reg boxmt[] = {
  {"__gc", boxgc}, {"__close", boxgc}, {NULL, NULL}
};

static void getBoxMT(lua_State *L)
{
  const char *key = "_UBOX*";
  if (luaL_getmetatable(L, key) == LUA_TNIL) {
    luaL_newlibtable(L, boxmt);
    luaL_setfuncs(L, boxmt, 0);
    lua_copy(L, -1, -2);
    lua_setfield(L, LUA_REGISTRYINDEX, key);
  }
}

static void newbox(lua_State *L)
{
  UBox *box = (UBox *)lua_newuserdatauv(L, sizeof(UBox), 0);
  box->box = NULL;
  box->bsize = 0;
  getBoxMT(L);
  lua_setmetatable(L, -2);
}

#define buffonstack(B)	((B)->b != (B)->init.b)
#define checkbufferlevel(B,idx) \
  lj_assertX(buffonstack(B) ? lua_touserdata(B->L, idx) != NULL \
                            : lua_touserdata(B->L, idx) == (void *)B, \
	     "buffer level does not match the stack slot")

static size_t newbuffsize(luaL_Buffer *B, size_t sz)
{
  size_t newsize = (B->size / 2) * 3;  /* buffer size * 1.5 */
  if ((size_t)-1 - sz < B->n)
    return luaL_error(B->L, "buffer too large");
  if (newsize < B->n + sz)
    newsize = B->n + sz;
  return newsize;
}

static char *prepbuffsize(luaL_Buffer *B, size_t sz, int boxidx)
{
  lua_State *L = B->L;
  lj_assertX(sz <= (size_t)-1 - B->n, "buffer size overflow");
  checkbufferlevel(B, boxidx);
  if (B->size - B->n >= sz)
    return B->b + B->n;
  {
    char *newbuff;
    size_t newsize = newbuffsize(B, sz);
    if (buffonstack(B)) {
      newbuff = (char *)resizebox(L, boxidx, newsize);
    } else {
      lua_remove(L, boxidx);
      newbox(L);
      lua_insert(L, boxidx);
      lua_toclose(L, boxidx);
      newbuff = (char *)resizebox(L, boxidx, newsize);
      memcpy(newbuff, B->b, B->n);
    }
    B->b = newbuff;
    B->size = newsize;
    return newbuff + B->n;
  }
}

LUALIB_API char *luaL_prepbuffsize(luaL_Buffer *B, size_t sz)
{
  return prepbuffsize(B, sz, -1);
}

LUALIB_API void luaL_addlstring(luaL_Buffer *B, const char *s, size_t l)
{
  if (l > 0) {
    char *b = prepbuffsize(B, l, -1);
    memcpy(b, s, l);
    luaL_addsize(B, l);
  }
}

LUALIB_API void luaL_addstring(luaL_Buffer *B, const char *s)
{
  luaL_addlstring(B, s, strlen(s));
}

LUALIB_API void luaL_pushresult(luaL_Buffer *B)
{
  lua_State *L = B->L;
  checkbufferlevel(B, -1);
  lua_pushlstring(L, B->b, B->n);
  if (buffonstack(B))
    lua_closeslot(L, -2);  /* close the box */
  lua_remove(L, -2);
}

LUALIB_API void luaL_pushresultsize(luaL_Buffer *B, size_t sz)
{
  luaL_addsize(B, sz);
  luaL_pushresult(B);
}

LUALIB_API void luaL_addvalue(luaL_Buffer *B)
{
  lua_State *L = B->L;
  size_t len;
  const char *s = lua_tolstring(L, -1, &len);
  char *b = prepbuffsize(B, len, -2);
  memcpy(b, s, len);
  luaL_addsize(B, len);
  lua_pop(L, 1);
}

LUALIB_API void luaL_buffinit(lua_State *L, luaL_Buffer *B)
{
  B->L = L;
  B->b = B->init.b;
  B->n = 0;
  B->size = LUAL_BUFFERSIZE;
  lua_pushlightuserdata(L, (void *)B);
}

LUALIB_API char *luaL_buffinitsize(lua_State *L, luaL_Buffer *B, size_t sz)
{
  luaL_buffinit(L, B);
  return prepbuffsize(B, sz, -1);
}

/* -- Reference management ------------------------------------------------ */

#define FREELIST_REF	0

/* Convert a stack index to an absolute index. */
#define abs_index(L, i) \
  ((i) > 0 || (i) <= LUA_REGISTRYINDEX ? (i) : lua_gettop(L) + (i) + 1)

LUALIB_API int luaL_ref(lua_State *L, int t)
{
  int ref;
  t = abs_index(L, t);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);  /* remove from stack */
    return LUA_REFNIL;  /* `nil' has a unique fixed reference */
  }
  lua_rawgeti(L, t, FREELIST_REF);  /* get first free element */
  ref = (int)lua_tointeger(L, -1);  /* ref = t[FREELIST_REF] */
  lua_pop(L, 1);  /* remove it from stack */
  if (ref != 0) {  /* any free element? */
    lua_rawgeti(L, t, ref);  /* remove it from list */
    lua_rawseti(L, t, FREELIST_REF);  /* (t[FREELIST_REF] = t[ref]) */
  } else {  /* no free elements */
    ref = (int)lua_objlen(L, t);
    ref++;  /* create new reference */
  }
  lua_rawseti(L, t, ref);
  return ref;
}

LUALIB_API void luaL_unref(lua_State *L, int t, int ref)
{
  if (ref >= 0) {
    t = abs_index(L, t);
    lua_rawgeti(L, t, FREELIST_REF);
    lua_rawseti(L, t, ref);  /* t[ref] = t[FREELIST_REF] */
    lua_pushinteger(L, ref);
    lua_rawseti(L, t, FREELIST_REF);  /* t[FREELIST_REF] = ref */
  }
}

/* -- Default allocator and panic function -------------------------------- */

static int panic(lua_State *L)
{
  const char *s = lua_tostring(L, -1);
  fputs("PANIC: unprotected error in call to Lua API (", stderr);
  fputs(s ? s : "?", stderr);
  fputc(')', stderr); fputc('\n', stderr);
  fflush(stderr);
  return 0;
}

/* Opt-in GC policy mode, read once when the state is created so that every
** embedder using luaL_newstate() honours LUAJIT_GC.  Unknown values are
** ignored silently.  Runtime collectgarbage("setpause"/"setstepmul")
** overrides this.  Default is the unchanged stock policy (200/200).
*/
static void gc_policy_mode(lua_State *L)
{
  const char *mode = getenv("LUAJIT_GC");
  if (mode == NULL) return;
  if (strcmp(mode, "memory") == 0) {
    lua_gc(L, LUA_GCSETPAUSE, LUAI_GCMEM_PAUSE);
    lua_gc(L, LUA_GCSETSTEPMUL, LUAI_GCMEM_MUL);
  } else if (strcmp(mode, "speed") == 0) {
    lua_gc(L, LUA_GCSETPAUSE, LUAI_GCPAUSE);
    lua_gc(L, LUA_GCSETSTEPMUL, LUAI_GCMUL);
  }
}

#ifndef LUAJIT_DISABLE_VMEVENT
/* PUC luaE_warnerror(L, "__gc"): an error in a finalizer becomes a warning
** (off by default, like PUC), never a propagated error. */
static int error_finalizer(lua_State *L)
{
  const char *s = lua_tostring(L, -1);
  lua_warning(L, "error in __gc (", 1);
  lua_warning(L, s ? s : "error object is not a string", 1);
  lua_warning(L, ")", 0);
  return 0;
}
#endif

#ifdef LUAJIT_USE_SYSMALLOC

#if LJ_64 && !LJ_GC64 && !defined(LUAJIT_USE_VALGRIND)
#error "Must use builtin allocator for 64 bit target"
#endif

static void *mem_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
  (void)ud;
  (void)osize;
  if (nsize == 0) {
    free(ptr);
    return NULL;
  } else {
    return realloc(ptr, nsize);
  }
}

LUALIB_API lua_State *luaL_newstate(void)
{
  lua_State *L = lua_newstate(mem_alloc, NULL);
  if (L) {
    G(L)->panic = panic;
    gc_policy_mode(L);
#ifndef LUAJIT_DISABLE_VMEVENT
    luaL_findtable(L, LUA_REGISTRYINDEX, LJ_VMEVENTS_REGKEY, LJ_VMEVENTS_HSIZE);
    lua_pushcfunction(L, error_finalizer);
    lua_rawseti(L, -2, VMEVENT_HASH(LJ_VMEVENT_ERRFIN));
    G(L)->vmevmask = VMEVENT_MASK(LJ_VMEVENT_ERRFIN);
    L->top--;
#endif
  }
  return L;
}

#else

LUALIB_API lua_State *luaL_newstate(void)
{
  lua_State *L;
#if LJ_64 && !LJ_GC64
  L = lj_state_newstate(LJ_ALLOCF_INTERNAL, NULL);
#else
  L = lua_newstate(LJ_ALLOCF_INTERNAL, NULL);
#endif
  if (L) {
    G(L)->panic = panic;
    gc_policy_mode(L);
#ifndef LUAJIT_DISABLE_VMEVENT
    luaL_findtable(L, LUA_REGISTRYINDEX, LJ_VMEVENTS_REGKEY, LJ_VMEVENTS_HSIZE);
    lua_pushcfunction(L, error_finalizer);
    lua_rawseti(L, -2, VMEVENT_HASH(LJ_VMEVENT_ERRFIN));
    G(L)->vmevmask = VMEVENT_MASK(LJ_VMEVENT_ERRFIN);
    L->top--;
#endif
  }
  return L;
}

#if LJ_64 && !LJ_GC64
LUA_API lua_State *lua_newstate(lua_Alloc f, void *ud)
{
  UNUSED(f); UNUSED(ud);
  fputs("Must use luaL_newstate() for 64 bit target\n", stderr);
  return NULL;
}
#endif

#endif

