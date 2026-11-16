/*
** Load and dump code.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#include <errno.h>
#include <stdio.h>

#define lj_load_c
#define LUA_CORE

#include "lua.h"
#include "lauxlib.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_func.h"
#include "lj_frame.h"
#include "lj_vm.h"
#include "lj_lex.h"
#include "lj_bcdump.h"
#include "lj_parse.h"

/* -- Load Lua source code and bytecode ----------------------------------- */

static TValue *cpparser(lua_State *L, lua_CFunction dummy, void *ud)
{
  LexState *ls = (LexState *)ud;
  GCproto *pt;
  GCfunc *fn;
  int bc;
  UNUSED(dummy);
  cframe_errfunc(L->cframe) = -1;  /* Inherit error function. */
  bc = lj_lex_setup(L, ls);
  if (ls->mode) {
    int xmode = 1;
    const char *mode = ls->mode;
    char c;
    while ((c = *mode++)) {
      if (c == (bc ? 'b' : 't')) xmode = 0;
      if (c == (LJ_FR2 ? 'W' : 'X')) ls->fr2 = !LJ_FR2;
    }
    if (xmode) {
      /* 5.4 names the actual chunk kind and the requested mode. */
      setstrV(L, L->top++, lj_err_str(L, bc ? LJ_ERR_XMODEB : LJ_ERR_XMODET));
      lj_err_throw(L, LUA_ERRSYNTAX);
    }
  }
  pt = bc ? lj_bcread(ls) : lj_parse(ls);
  if (ls->fr2 == LJ_FR2) {
    fn = lj_func_newL_empty(L, pt, tabref(L->env));
    /* Don't combine above/below into one statement. */
    setfuncV(L, L->top++, fn);
  } else {
    /* Non-native generation returns a dumpable, but non-runnable prototype. */
    setprotoV(L, L->top++, pt);
  }
  return NULL;
}

LUA_API int lua_loadx(lua_State *L, lua_Reader reader, void *data,
		      const char *chunkname, const char *mode)
{
  LexState ls;
  int status;
  ls.rfunc = reader;
  ls.rdata = data;
  ls.chunkarg = chunkname ? chunkname : "?";
  ls.mode = mode;
  lj_buf_init(L, &ls.sb);
  status = lj_vm_cpcall(L, NULL, &ls, cpparser);
  lj_lex_cleanup(L, &ls);
  lj_gc_check(L);
  return status;
}

LUA_API int lua_load(lua_State *L, lua_Reader reader, void *data,
		     const char *chunkname)
{
  return lua_loadx(L, reader, data, chunkname, NULL);
}

typedef struct FileReaderCtx {
  FILE *fp;
  char pre[2];  /* optional synthetic '\n' (skipped '#' line) + first char */
  int prelen;
  char buf[LUAL_BUFFERSIZE];
} FileReaderCtx;

static const char *reader_file(lua_State *L, void *ud, size_t *size)
{
  FileReaderCtx *ctx = (FileReaderCtx *)ud;
  UNUSED(L);
  if (ctx->prelen > 0) {
    *size = (size_t)ctx->prelen;
    ctx->prelen = 0;
    return ctx->pre;
  }
  if (feof(ctx->fp)) return NULL;
  *size = fread(ctx->buf, 1, sizeof(ctx->buf), ctx->fp);
  return *size > 0 ? ctx->buf : NULL;
}

LUALIB_API int luaL_loadfilex(lua_State *L, const char *filename,
			      const char *mode)
{
  FileReaderCtx ctx;
  int status;
  const char *chunkname;
  int err = 0;
  if (filename) {
    chunkname = lua_pushfstring(L, "@%s", filename);
    ctx.fp = fopen(filename, "rb");
    if (ctx.fp == NULL) {
      L->top--;
      lua_pushfstring(L, "cannot open %s: %s", filename, strerror(errno));
      return LUA_ERRFILE;
    }
  } else {
    ctx.fp = stdin;
    chunkname = "=stdin";
  }
  /* PUC 5.4 luaL_loadfilex: skip an optional BOM, then a first line that
  ** starts with '#'. A synthetic '\n' after the skipped line keeps later
  ** line numbers and error positions right. */
  ctx.prelen = 0;
  {
    int c = fgetc(ctx.fp);
    if (c == 0xEF && fgetc(ctx.fp) == 0xBB && fgetc(ctx.fp) == 0xBF)
      c = fgetc(ctx.fp);  /* valid BOM: ignore it */
    if (c == '#') {  /* shebang/exec file: skip the first line */
      do { c = fgetc(ctx.fp); } while (c != EOF && c != '\n');
      if (c == '\n') c = fgetc(ctx.fp);
      if (c != EOF) {
	if (c == BCDUMP_HEAD1) {
	  /* Binary chunk after the comment line: no synthetic newline, the
	  ** reader must see the ESC signature first (PUC reopens in binary). */
	  ctx.pre[ctx.prelen++] = (char)c;
	} else {
	  ctx.pre[ctx.prelen++] = '\n';
	  ctx.pre[ctx.prelen++] = (char)c;
	}
      }
    } else if (c != EOF) {
      ctx.pre[ctx.prelen++] = (char)c;
    }
  }
  status = lua_loadx(L, reader_file, &ctx, chunkname, mode);
  if (ferror(ctx.fp)) err = errno;
  if (filename) {
    fclose(ctx.fp);
    L->top--;
    copyTV(L, L->top-1, L->top);
  }
  if (err) {
    const char *fname = filename ? filename : "stdin";
    L->top--;
    lua_pushfstring(L, "cannot read %s: %s", fname, strerror(err));
    return LUA_ERRFILE;
  }
  return status;
}

LUALIB_API int luaL_loadfile(lua_State *L, const char *filename)
{
  return luaL_loadfilex(L, filename, NULL);
}

typedef struct StringReaderCtx {
  const char *str;
  size_t size;
} StringReaderCtx;

static const char *reader_string(lua_State *L, void *ud, size_t *size)
{
  StringReaderCtx *ctx = (StringReaderCtx *)ud;
  UNUSED(L);
  if (ctx->size == 0) return NULL;
  *size = ctx->size;
  ctx->size = 0;
  return ctx->str;
}

LUALIB_API int luaL_loadbufferx(lua_State *L, const char *buf, size_t size,
				const char *name, const char *mode)
{
  StringReaderCtx ctx;
  ctx.str = buf;
  ctx.size = size;
  return lua_loadx(L, reader_string, &ctx, name, mode);
}

LUALIB_API int luaL_loadbuffer(lua_State *L, const char *buf, size_t size,
			       const char *name)
{
  return luaL_loadbufferx(L, buf, size, name, NULL);
}

LUALIB_API int luaL_loadstring(lua_State *L, const char *s)
{
  return luaL_loadbuffer(L, s, strlen(s), s);
}

/* -- Dump bytecode ------------------------------------------------------- */

LUA_API int lua_dump(lua_State *L, lua_Writer writer, void *data)
{
  cTValue *o = L->top-1;
  uint32_t flags = LJ_FR2*BCDUMP_F_FR2;  /* Default mode for legacy C API. */
  lj_checkapi(L->top > L->base, "top slot empty");
  if (tvisfunc(o) && isluafunc(funcV(o)))
    return lj_bcwrite(L, funcproto(funcV(o)), writer, data, flags);
  else
    return 1;
}

