/*
** I/O library.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2011 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#include <errno.h>
#include <stdio.h>
#include <ctype.h>

#define lib_io_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_state.h"
#include "lj_strfmt.h"
#include "lj_ff.h"
#include "lj_lib.h"
#include "lj_i64.h"
#include "lj_strscan.h"

/* Userdata payload for I/O file. The first two fields match PUC's luaL_Stream
** ({FILE *f; lua_CFunction closef}), which C modules inspect via LUA_FILEHANDLE
** (Lua 5.4 ABI). Internal type flags follow after that prefix. */
typedef struct IOFileUD {
  FILE *fp;		/* File handle (luaL_Stream.f). */
  lua_CFunction closef;	/* luaL_Stream.closef (NULL for standard handles). */
  uint32_t type;	/* LuaJIT-internal file type/flags. */
} IOFileUD;

#define IOFILE_TYPE_FILE	0	/* Regular file. */
#define IOFILE_TYPE_PIPE	1	/* Pipe. */
#define IOFILE_TYPE_STDF	2	/* Standard file handle. */
#define IOFILE_TYPE_MASK	3

#define IOFILE_FLAG_CLOSE	4	/* Close after io.lines() iterator. */

static int lj_cf_io_method_close(lua_State *L);  /* luaL_Stream.closef */

#define IOSTDF_UD(L, id)	(&gcref(G(L)->gcroot[(id)])->ud)
#define IOSTDF_IOF(L, id)	((IOFileUD *)uddata(IOSTDF_UD(L, (id))))

/* -- Open/close helpers -------------------------------------------------- */

static IOFileUD *io_tofilep(lua_State *L)
{
  if (!(L->base < L->top && tvisudata(L->base) &&
	udataV(L->base)->udtype == UDTYPE_IO_FILE))
    lj_err_argtype(L, 1, "FILE*");
  return (IOFileUD *)uddata(udataV(L->base));
}

static IOFileUD *io_tofile(lua_State *L)
{
  IOFileUD *iof = io_tofilep(L);
  if (iof->fp == NULL)
    lj_err_caller(L, LJ_ERR_IOCLFL);
  return iof;
}

static IOFileUD *io_stdfile(lua_State *L, ptrdiff_t id)
{
  IOFileUD *iof = IOSTDF_IOF(L, id);
  if (iof->fp == NULL)
    luaL_error(L, "default %s file is closed",
	       id == GCROOT_IO_INPUT ? "input" : "output");
  return iof;
}

/* Exact integer conversion, like 5.4's luaL_checkinteger: a numeral string
** is scanned with 5.4 rules and a float is accepted only if it is exactly
** representable as an integer (1.5 raises "number has no integer
** representation", 2.0 is accepted as 2).
*/
static int64_t io_toint64(lua_State *L, int narg, int64_t def)
{
  TValue *o = L->base + narg-1;
  int64_t i64;
  if (o >= L->top || tvisnil(o)) return def;
  if (tvisi64(o)) return i64V(o);
#if LJ_GC64
  if (tvisi47w(o)) return (int64_t)intV47(o);
#endif
  if (!(tvisnumber(o) || (tvisstr(o) && lj_strscan_number(strV(o), o))))
    lj_err_argt(L, narg, LUA_TNUMBER);
  if (tvisint(o))
    return (int64_t)intV(o);
#if LJ_GC64
  if (tvisi47w(o)) return (int64_t)intV47(o);
#endif
  if (!lj_i64_numtoint(numV(o), &i64))
    lj_err_arg(L, narg, LJ_ERR_NUMNOINT);
  return i64;
}

static IOFileUD *io_file_new(lua_State *L)
{
  IOFileUD *iof = (IOFileUD *)lua_newuserdatauv(L, sizeof(IOFileUD), 0);  /* PUC: no user values. */
  GCudata *ud = udataV(L->top-1);
  ud->udtype = UDTYPE_IO_FILE;
  /* NOBARRIER: The GCudata is new (marked white). */
  setgcrefr(ud->metatable, curr_func(L)->c.env);
  iof->fp = NULL;
  iof->closef = NULL;
  iof->type = IOFILE_TYPE_FILE;
  return iof;
}

static IOFileUD *io_file_open(lua_State *L, const char *mode)
{
  const char *fname = strdata(lj_lib_checkstr(L, 1));
  IOFileUD *iof = io_file_new(L);
  iof->fp = fopen(fname, mode);
  if (iof->fp == NULL)
    lj_err_callerv(L, LJ_ERR_IOOPENF, fname, strerror(errno));  /* 5.4 wording */
  iof->closef = lj_cf_io_method_close;  /* luaL_Stream ABI for C modules */
  return iof;
}

static int io_file_close(lua_State *L, IOFileUD *iof)
{
  int ok;
  if ((iof->type & IOFILE_TYPE_MASK) == IOFILE_TYPE_FILE) {
    ok = (fclose(iof->fp) == 0);
  } else if ((iof->type & IOFILE_TYPE_MASK) == IOFILE_TYPE_PIPE) {
    int stat = -1;
#if LJ_TARGET_POSIX
    stat = pclose(iof->fp);
#elif LJ_TARGET_WINDOWS && !LJ_TARGET_XBOXONE && !LJ_TARGET_UWP
    stat = _pclose(iof->fp);
#endif
#if LJ_52
    iof->fp = NULL;
    return luaL_execresult(L, stat);
#else
    ok = (stat != -1);
#endif
  } else {
    lj_assertL((iof->type & IOFILE_TYPE_MASK) == IOFILE_TYPE_STDF,
	       "close of unknown FILE* type");
    setnilV(L->top++);
    lua_pushliteral(L, "cannot close standard file");
    return 2;
  }
  iof->fp = NULL;
  return luaL_fileresult(L, ok, NULL);
}

/* -- Read/write helpers -------------------------------------------------- */

/* 5.4 read_number: buffer a valid prefix of a numeral, then convert it with
** the 5.4 tonumber rules (integer syntax -> integer, anything with a decimal
** point or exponent -> float).
*/
#define IO_MAXLENNUM	200

typedef struct IONum {
  FILE *fp;
  int c;		/* current look-ahead character */
  int n;
  char buf[IO_MAXLENNUM + 1];
} IONum;

static int io_num_nextc(IONum *rn)
{
  if (rn->n >= IO_MAXLENNUM) {  /* buffer overflow: invalidate result */
    rn->buf[0] = '\0';
    return 0;
  }
  rn->buf[rn->n++] = (char)rn->c;
  rn->c = getc(rn->fp);
  return 1;
}

static int io_num_test2(IONum *rn, const char *set)
{
  if (rn->c == set[0] || rn->c == set[1])
    return io_num_nextc(rn);
  return 0;
}

static int io_num_digits(IONum *rn, int hex)
{
  int count = 0;
  while ((hex ? isxdigit(rn->c) : isdigit(rn->c)) && io_num_nextc(rn))
    count++;
  return count;
}

static int io_file_readnum(lua_State *L, FILE *fp)
{
  IONum rn;
  int count = 0, hex = 0;
  TValue o;
  rn.fp = fp; rn.n = 0;
  do { rn.c = getc(fp); } while (isspace(rn.c));  /* skip spaces */
  io_num_test2(&rn, "-+");  /* optional sign */
  if (io_num_test2(&rn, "00")) {
    if (io_num_test2(&rn, "xX")) hex = 1;
    else count = 1;  /* count initial '0' as a valid digit */
  }
  count += io_num_digits(&rn, hex);  /* integral part */
  if (io_num_test2(&rn, "."))  /* decimal point? */
    count += io_num_digits(&rn, hex);  /* fractional part */
  if (count > 0 && io_num_test2(&rn, hex ? "pP" : "eE")) {
    io_num_test2(&rn, "-+");  /* exponent sign */
    io_num_digits(&rn, 0);  /* exponent digits */
  }
  ungetc(rn.c, fp);  /* unread look-ahead char */
  rn.buf[rn.n] = '\0';
  if (lj_strscan_number64(L, lj_str_new(L, rn.buf, (size_t)rn.n), &o)) {
    copyTV(L, L->top++, &o);
    return 1;
  }
  setnilV(L->top++);
  return 0;
}

static int io_file_readline(lua_State *L, FILE *fp, MSize chop)
{
  MSize m = LUAL_BUFFERSIZE, n = 0;
  int c = EOF;
  char *buf = lj_buf_tmp(L, m);
  for (;;) {
    c = getc(fp);
    if (c == EOF || c == '\n') break;
    if (n >= m) { m += m; buf = lj_buf_tmp(L, m); }
    buf[n++] = (char)c;  /* keeps embedded zero bytes */
  }
  if (chop == 0 && c == '\n') {  /* 'L' keeps the end-of-line */
    if (n >= m) { m += m; buf = lj_buf_tmp(L, m); }
    buf[n++] = '\n';
  }
  setstrV(L, L->top++, lj_str_new(L, buf, (size_t)n));
  lj_gc_check(L);
  return (c == '\n' || n > 0);
}

static void io_file_readall(lua_State *L, FILE *fp)
{
  MSize m, n;
  for (m = LUAL_BUFFERSIZE, n = 0; ; m += m) {
    char *buf = lj_buf_tmp(L, m);
    n += (MSize)fread(buf+n, 1, m-n, fp);
    if (n != m) {
      setstrV(L, L->top++, lj_str_new(L, buf, (size_t)n));
      lj_gc_check(L);
      return;
    }
  }
}

static int io_file_readlen(lua_State *L, FILE *fp, MSize m)
{
  if (m) {
    char *buf = lj_buf_tmp(L, m);
    MSize n = (MSize)fread(buf, 1, m, fp);
    setstrV(L, L->top++, lj_str_new(L, buf, (size_t)n));
    lj_gc_check(L);
    return n > 0;
  } else {
    int c = getc(fp);
    ungetc(c, fp);
    setstrV(L, L->top++, &G(L)->strempty);
    return (c != EOF);
  }
}

static int io_file_read(lua_State *L, IOFileUD *iof, int start)
{
  FILE *fp = iof->fp;
  int ok, n, nargs = (int)(L->top - L->base) - start;
  clearerr(fp);
  if (nargs == 0) {
    ok = io_file_readline(L, fp, 1);
    n = start+1;  /* Return 1 result. */
  } else {
    /* The results plus the buffers go on top of the args. */
    luaL_checkstack(L, nargs+LUA_MINSTACK, "too many arguments");
    ok = 1;
    for (n = start; nargs-- && ok; n++) {
      if (tvisnumber(L->base+n)) {
	ok = io_file_readlen(L, fp, (MSize)io_toint64(L, n+1, 0));
      } else {
	const char *p = strdata(lj_lib_checkstr(L, n+1));
	if (p[0] == '*') p++;
	if (p[0] == 'n')
	  ok = io_file_readnum(L, fp);
	else if ((p[0] & ~0x20) == 'L')
	  ok = io_file_readline(L, fp, (p[0] == 'l'));
	else if (p[0] == 'a')
	  io_file_readall(L, fp);
	else
	  lj_err_arg(L, n+1, LJ_ERR_INVFMT);
      }
    }
  }
  if (ferror(fp))
    return luaL_fileresult(L, 0, NULL);
  if (!ok)
    setnilV(L->top-1);  /* Replace last result with nil. */
  return n - start;
}

static int io_file_write(lua_State *L, IOFileUD *iof, int start)
{
  FILE *fp = iof->fp;
  cTValue *tv;
  int status = 1;
  for (tv = L->base+start; tv < L->top; tv++) {
    MSize len;
    const char *p = lj_strfmt_wstrnum(L, tv, &len);
    if (!p)
      lj_err_argt(L, (int)(tv - L->base) + 1, LUA_TSTRING);
    status = status && (fwrite(p, 1, len, fp) == len);
  }
  /* 5.4: write returns the file handle (for chaining), not a boolean. */
  if (status) {
    L->top = L->base+1;
    if (start == 0)
      setudataV(L, L->base, IOSTDF_UD(L, GCROOT_IO_OUTPUT));
    return 1;
  }
  return luaL_fileresult(L, status, NULL);
}

static int io_file_iter(lua_State *L)
{
  GCfunc *fn = curr_func(L);
  IOFileUD *iof = uddata(udataV(&fn->c.upvalue[0]));
  int n = fn->c.nupvalues - 1;
  if (iof->fp == NULL)  /* 5.4 io.lines helper wording */
    luaL_error(L, "file is already closed");
  L->top = L->base;
  if (n) {  /* Copy upvalues with options to stack. */
    lj_state_checkstack(L, (MSize)n);
    memcpy(L->top, &fn->c.upvalue[1], n*sizeof(TValue));
    L->top += n;
  }
  n = io_file_read(L, iof, 0);
  if (n < 1) {  /* EOF: 5.4 closes an io.lines file, so a later call errors. */
    if (iof->type & IOFILE_FLAG_CLOSE)
      io_file_close(L, iof);
    return 0;
  }
  if (!tvisnil(L->top-n))  /* read at least one value? */
    return n;
  if (n > 1)  /* error result: nil, message, errno */
    lj_err_callermsg(L, strVdata(L->top-n+1));
  if (iof->type & IOFILE_FLAG_CLOSE)
    io_file_close(L, iof);  /* Return values are ignored. */
  return 0;
}

static int io_file_lines(lua_State *L)
{
  int n = (int)(L->top - L->base);
  /* PUC 5.4 MAXARGLINE = 250; the iterator closure has n formats + 1 file. */
  luaL_argcheck(L, n-1 <= 250, 252, "too many arguments");  /* n includes the file */
  lua_pushcclosure(L, io_file_iter, n);
  return 1;
}

/* -- I/O file methods ---------------------------------------------------- */

#define LJLIB_MODULE_io_method

LJLIB_CF(io_method_close)
{
  /* A file method: self is argument #1; a dot call without it is PUC's
  ** "FILE* expected, got no value" (only io.close() may omit the file). */
  IOFileUD *iof = io_tofile(L);
  return io_file_close(L, iof);
}

LJLIB_CF(io_method_read)
{
  return io_file_read(L, io_tofile(L), 1);
}

LJLIB_CF(io_method_write)		LJLIB_REC(io_write 0)
{
  return io_file_write(L, io_tofile(L), 1);
}

LJLIB_CF(io_method_flush)		LJLIB_REC(io_flush 0)
{
  return luaL_fileresult(L, fflush(io_tofile(L)->fp) == 0, NULL);
}

#if LJ_32 && defined(__ANDROID__) && __ANDROID_API__ < 24
/* The Android NDK is such an unmatched marvel of engineering. */
extern int fseeko32(FILE *, long int, int) __asm__("fseeko");
extern long int ftello32(FILE *) __asm__("ftello");
#define fseeko(fp, pos, whence)	(fseeko32((fp), (pos), (whence)))
#define ftello(fp)		(ftello32((fp)))
#endif

LJLIB_CF(io_method_seek)
{
  FILE *fp = io_tofile(L)->fp;
  int opt = lj_lib_checkopt(L, 2, 1, "\3set\3cur\3end");
  int64_t ofs;
  int res;
  if (opt == 0) opt = SEEK_SET;
  else if (opt == 1) opt = SEEK_CUR;
  else if (opt == 2) opt = SEEK_END;
  ofs = io_toint64(L, 3, 0);
#if LJ_TARGET_POSIX
  res = fseeko(fp, ofs, opt);
#elif _MSC_VER >= 1400
  res = _fseeki64(fp, ofs, opt);
#elif defined(__MINGW32__)
  res = fseeko64(fp, ofs, opt);
#else
  res = fseek(fp, (long)ofs, opt);
#endif
  if (res)
    return luaL_fileresult(L, 0, NULL);
#if LJ_TARGET_POSIX
  ofs = ftello(fp);
#elif _MSC_VER >= 1400
  ofs = _ftelli64(fp);
#elif defined(__MINGW32__)
  ofs = ftello64(fp);
#else
  ofs = (int64_t)ftell(fp);
#endif
  setint64V(L->top++, ofs);
  return 1;
}

LJLIB_CF(io_method_setvbuf)
{
  FILE *fp = io_tofile(L)->fp;
  int opt = lj_lib_checkopt(L, 2, -1, "\4full\4line\2no");
  size_t sz = (size_t)io_toint64(L, 3, LUAL_BUFFERSIZE);
  if (opt == 0) opt = _IOFBF;
  else if (opt == 1) opt = _IOLBF;
  else if (opt == 2) opt = _IONBF;
  return luaL_fileresult(L, setvbuf(fp, NULL, opt, sz) == 0, NULL);
}

LJLIB_CF(io_method_lines)
{
  io_tofile(L);
  return io_file_lines(L);
}

LJLIB_CF(io_method___gc)
{
  IOFileUD *iof = io_tofilep(L);
  if (iof->fp != NULL && (iof->type & IOFILE_TYPE_MASK) != IOFILE_TYPE_STDF)
    io_file_close(L, iof);
  return 0;
}

/* 5.4: file handles are to-be-closed values; io.lines() returns the file as
** the generic for's 4th value, so the loop closes it on break/exit. */
LJLIB_CF(io_method___close)
{
  IOFileUD *iof = io_tofilep(L);
  if (iof->fp != NULL && (iof->type & IOFILE_TYPE_MASK) != IOFILE_TYPE_STDF)
    io_file_close(L, iof);
  return 0;
}

LJLIB_CF(io_method___tostring)
{
  IOFileUD *iof = io_tofilep(L);
  if (iof->fp != NULL)
    lua_pushfstring(L, "file (%p)", iof->fp);
  else
    lua_pushliteral(L, "file (closed)");
  return 1;
}

LJLIB_PUSH(top-1) LJLIB_SET(__index)

#include "lj_libdef.h"

/* -- I/O library functions ----------------------------------------------- */

#define LJLIB_MODULE_io

LJLIB_PUSH(top-2) LJLIB_SET(!)  /* Set environment. */

/* 5.4: a mode must match [rwa] '+'? 'b'* . */
static int io_checkmode(const char *mode)
{
  if (*mode == '\0' || !strchr("rwa", *mode)) return 0;
  mode++;
  if (*mode == '+') mode++;
  return mode[strspn(mode, "b")] == '\0';
}

LJLIB_CF(io_open)
{
  const char *fname = strdata(lj_lib_checkstr(L, 1));
  GCstr *s = lj_lib_optstr(L, 2);
  const char *mode = s ? strdata(s) : "r";
  IOFileUD *iof;
  luaL_argcheck(L, io_checkmode(mode), 2, "invalid mode");
  iof = io_file_new(L);
  iof->fp = fopen(fname, mode);
  if (iof->fp != NULL) iof->closef = lj_cf_io_method_close;
  return iof->fp != NULL ? 1 : luaL_fileresult(L, 0, fname);
}

LJLIB_CF(io_popen)
{
#if LJ_TARGET_POSIX || (LJ_TARGET_WINDOWS && !LJ_TARGET_XBOXONE && !LJ_TARGET_UWP)
  const char *fname = strdata(lj_lib_checkstr(L, 1));
  GCstr *s = lj_lib_optstr(L, 2);
  const char *mode = s ? strdata(s) : "r";
  IOFileUD *iof = io_file_new(L);
  iof->type = IOFILE_TYPE_PIPE;
  iof->closef = NULL;
#if LJ_TARGET_POSIX
  fflush(NULL);
  iof->fp = popen(fname, mode);
#else
  iof->fp = _popen(fname, mode);
#endif
  return iof->fp != NULL ? 1 : luaL_fileresult(L, 0, fname);
#else
  return luaL_error(L, LUA_QL("popen") " not supported");
#endif
}

LJLIB_CF(io_tmpfile)
{
  IOFileUD *iof = io_file_new(L);
#if LJ_TARGET_PS3 || LJ_TARGET_PS4 || LJ_TARGET_PS5 || LJ_TARGET_PSVITA || LJ_TARGET_NX
  iof->fp = NULL; errno = ENOSYS;
#else
  iof->fp = tmpfile();
#endif
  return iof->fp != NULL ? 1 : luaL_fileresult(L, 0, NULL);
}

LJLIB_CF(io_close)
{
  IOFileUD *iof;
  if (L->base < L->top) {
    iof = io_tofile(L);
  } else {
    iof = IOSTDF_IOF(L, GCROOT_IO_OUTPUT);
    if (iof->fp == NULL)
      lj_err_caller(L, LJ_ERR_IOCLFL);
  }
  return io_file_close(L, iof);
}

LJLIB_CF(io_read)
{
  return io_file_read(L, io_stdfile(L, GCROOT_IO_INPUT), 0);
}

LJLIB_CF(io_write)		LJLIB_REC(io_write GCROOT_IO_OUTPUT)
{
  return io_file_write(L, io_stdfile(L, GCROOT_IO_OUTPUT), 0);
}

LJLIB_CF(io_flush)		LJLIB_REC(io_flush GCROOT_IO_OUTPUT)
{
  return luaL_fileresult(L, fflush(io_stdfile(L, GCROOT_IO_OUTPUT)->fp) == 0, NULL);
}

static int io_std_getset(lua_State *L, ptrdiff_t id, const char *mode)
{
  if (L->base < L->top && !tvisnil(L->base)) {
    if (tvisstr(L->base) || tvisnumber(L->base)) {
      io_file_open(L, mode);  /* 5.4: a filename opens the file */
    } else {
      io_tofile(L);  /* check that it's a valid file handle */
      L->top = L->base+1;
    }
    /* NOBARRIER: The standard I/O handles are GC roots. */
    setgcref(G(L)->gcroot[id], gcV(L->top-1));
  } else {
    setudataV(L, L->top++, IOSTDF_UD(L, id));
  }
  return 1;
}

LJLIB_CF(io_input)
{
  return io_std_getset(L, GCROOT_IO_INPUT, "r");
}

LJLIB_CF(io_output)
{
  return io_std_getset(L, GCROOT_IO_OUTPUT, "w");
}

LJLIB_CF(io_lines)
{
  int toclose = 0;
  TValue filetv;
  if (L->base == L->top) setnilV(L->top++);
  if (!tvisnil(L->base)) {  /* io.lines(fname, ...formats) */
    IOFileUD *iof = io_file_open(L, "r");
    iof->type = IOFILE_TYPE_FILE|IOFILE_FLAG_CLOSE;
    L->top--;
    setudataV(L, L->base, udataV(L->top));
    filetv = *L->base;
    toclose = 1;
  } else {  /* io.lines() iterates over the default input. */
    if (IOSTDF_IOF(L, GCROOT_IO_INPUT)->fp == NULL)
      luaL_error(L, "default input file is closed");
    setudataV(L, L->base, IOSTDF_UD(L, GCROOT_IO_INPUT));
  }
  io_file_lines(L);  /* closure replaces the upvalues on the stack */
  if (toclose) {  /* 5.4: iterator, state, control, to-be-closed file */
    setnilV(L->top++);
    setnilV(L->top++);
    copyTV(L, L->top, &filetv); L->top++;
    return 4;
  }
  return 1;
}

LJLIB_CF(io_type)
{
  cTValue *o = lj_lib_checkany(L, 1);
  if (!(tvisudata(o) && udataV(o)->udtype == UDTYPE_IO_FILE))
    setnilV(L->top++);
  else if (((IOFileUD *)uddata(udataV(o)))->fp != NULL)
    lua_pushliteral(L, "file");
  else
    lua_pushliteral(L, "closed file");
  return 1;
}

#include "lj_libdef.h"

/* ------------------------------------------------------------------------ */

static GCobj *io_std_new(lua_State *L, FILE *fp, const char *name)
{
  IOFileUD *iof = (IOFileUD *)lua_newuserdatauv(L, sizeof(IOFileUD), 0);  /* PUC: no user values. */
  GCudata *ud = udataV(L->top-1);
  ud->udtype = UDTYPE_IO_FILE;
  /* NOBARRIER: The GCudata is new (marked white). */
  setgcref(ud->metatable, gcV(L->top-3));
  iof->fp = fp;
  iof->closef = NULL;  /* PUC standard streams are not luaL_Stream-closeable */
  iof->type = IOFILE_TYPE_STDF;
  lua_setfield(L, -2, name);
  return obj2gco(ud);
}

LUALIB_API int luaopen_io(lua_State *L)
{
  LJ_LIB_REG(L, NULL, io_method);
  /* 5.4: __name gives the type name used in error messages. */
  lua_pushstring(L, LUA_FILEHANDLE);
  lua_setfield(L, -2, "__name");
  copyTV(L, L->top, L->top-1); L->top++;
  lua_setfield(L, LUA_REGISTRYINDEX, LUA_FILEHANDLE);
  LJ_LIB_REG(L, LUA_IOLIBNAME, io);
  setgcref(G(L)->gcroot[GCROOT_IO_INPUT], io_std_new(L, stdin, "stdin"));
  setgcref(G(L)->gcroot[GCROOT_IO_OUTPUT], io_std_new(L, stdout, "stdout"));
  io_std_new(L, stderr, "stderr");
  return 1;
}

