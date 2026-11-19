/*
** String formatting.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#include <stdio.h>

#define lj_strfmt_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_meta.h"
#include "lj_state.h"
#include "lj_char.h"
#include "lj_strfmt.h"
#if LJ_HASFFI
#include "lj_ctype.h"
#endif
#include "lj_lib.h"

/* -- Format parser ------------------------------------------------------- */

static const uint8_t strfmt_map[('x'-'A')+1] = {
  STRFMT_A,0,0,0,STRFMT_E,STRFMT_F,STRFMT_G,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,STRFMT_X,0,0,
  0,0,0,0,0,0,
  STRFMT_A,0,STRFMT_C,STRFMT_D,STRFMT_E,STRFMT_F,STRFMT_G,0,STRFMT_I,0,0,0,0,
  0,STRFMT_O,STRFMT_P,STRFMT_Q,0,STRFMT_S,0,STRFMT_U,0,0,STRFMT_X
};

SFormat LJ_FASTCALL lj_strfmt_parse(FormatState *fs)
{
  const uint8_t *p = fs->p, *e = fs->e;
  fs->str = (const char *)p;
  for (; p < e; p++) {
    if (*p == '%') {  /* Escape char? */
      if (p[1] == '%') {  /* '%%'? */
	fs->p = ++p+1;
	goto retlit;
      } else {
	SFormat sf = 0;
	uint32_t c;
	if (p != (const uint8_t *)fs->str)
	  break;
	for (p++; (uint32_t)*p - ' ' <= (uint32_t)('0' - ' '); p++) {
	  /* Parse flags. */
	  if (*p == '-') sf |= STRFMT_F_LEFT;
	  else if (*p == '+') sf |= STRFMT_F_PLUS;
	  else if (*p == '0') sf |= STRFMT_F_ZERO;
	  else if (*p == ' ') sf |= STRFMT_F_SPACE;
	  else if (*p == '#') sf |= STRFMT_F_ALT;
	  else break;
	}
	if ((uint32_t)*p - '0' < 10) {  /* Parse width. */
	  uint32_t width = (uint32_t)*p++ - '0';
	  if ((uint32_t)*p - '0' < 10)
	    width = (uint32_t)*p++ - '0' + width*10;
	  sf |= (width << STRFMT_SH_WIDTH);
	}
	if (*p == '.') {  /* Parse precision. */
	  uint32_t prec = 0;
	  p++;
	  if ((uint32_t)*p - '0' < 10) {
	    prec = (uint32_t)*p++ - '0';
	    if ((uint32_t)*p - '0' < 10)
	      prec = (uint32_t)*p++ - '0' + prec*10;
	  }
	  sf |= ((prec+1) << STRFMT_SH_PREC);
	}
	/* Parse conversion. */
	c = (uint32_t)*p - 'A';
	if (LJ_LIKELY(c <= (uint32_t)('x' - 'A'))) {
	  uint32_t sx = strfmt_map[c];
	  if (sx) {
	    fs->p = p+1;
	    return (sf | sx | ((c & 0x20) ? 0 : STRFMT_F_UPPER));
	  }
	}
	/* Return error location. */
	if (*p >= 32) p++;
	fs->len = (MSize)(p - (const uint8_t *)fs->str);
	fs->p = fs->e;
	return STRFMT_ERR;
      }
    }
  }
  fs->p = p;
retlit:
  fs->len = (MSize)(p - (const uint8_t *)fs->str);
  return fs->len ? STRFMT_LIT : STRFMT_EOF;
}

/* -- Raw conversions ----------------------------------------------------- */

#define WINT_R(x, sh, sc) \
  { uint32_t d = (x*(((1<<sh)+sc-1)/sc))>>sh; x -= d*sc; *p++ = (char)('0'+d); }

/* Write integer to buffer. */
char * LJ_FASTCALL lj_strfmt_wint(char *p, int32_t k)
{
  uint32_t u = (uint32_t)k;
  if (k < 0) { u = ~u+1u; *p++ = '-'; }
  if (u < 10000) {
    if (u < 10) goto dig1;
    if (u < 100) goto dig2;
    if (u < 1000) goto dig3;
  } else {
    uint32_t v = u / 10000; u -= v * 10000;
    if (v < 10000) {
      if (v < 10) goto dig5;
      if (v < 100) goto dig6;
      if (v < 1000) goto dig7;
    } else {
      uint32_t w = v / 10000; v -= w * 10000;
      if (w >= 10) WINT_R(w, 10, 10)
      *p++ = (char)('0'+w);
    }
    WINT_R(v, 23, 1000)
    dig7: WINT_R(v, 12, 100)
    dig6: WINT_R(v, 10, 10)
    dig5: *p++ = (char)('0'+v);
  }
  WINT_R(u, 23, 1000)
  dig3: WINT_R(u, 12, 100)
  dig2: WINT_R(u, 10, 10)
  dig1: *p++ = (char)('0'+u);
  return p;
}
#undef WINT_R

/* Write pointer to buffer. */
char * LJ_FASTCALL lj_strfmt_wptr(char *p, const void *v)
{
  ptrdiff_t x = (ptrdiff_t)v;
  MSize i, n = STRFMT_MAXBUF_PTR;
  if (x == 0) {
    *p++ = 'N'; *p++ = 'U'; *p++ = 'L'; *p++ = 'L';
    return p;
  }
#if LJ_64
  /* Shorten output for 64 bit pointers. */
  n = 2+2*4+((x >> 32) ? 2+2*(lj_fls((uint32_t)(x >> 32))>>3) : 0);
#endif
  p[0] = '0';
  p[1] = 'x';
  for (i = n-1; i >= 2; i--, x >>= 4)
    p[i] = "0123456789abcdef"[(x & 15)];
  return p+n;
}

/* Write ULEB128 to buffer. */
char * LJ_FASTCALL lj_strfmt_wuleb128(char *p, uint32_t v)
{
  for (; v >= 0x80; v >>= 7)
    *p++ = (char)((v & 0x7f) | 0x80);
  *p++ = (char)v;
  return p;
}

/* Return string or write number to tmp buffer and return pointer to start. */
const char *lj_strfmt_wstrnum(lua_State *L, cTValue *o, MSize *lenp)
{
  SBuf *sb;
  if (tvisstr(o)) {
    *lenp = strV(o)->len;
    return strVdata(o);
  } else if (tvisbuf(o)) {
    SBufExt *sbx = bufV(o);
    *lenp = sbufxlen(sbx);
    return sbx->r ? sbx->r : "";
  } else if (tvisi47w(o)) {  /* widened 47-bit inline integer */
    sb = lj_strfmt_putfxint(lj_buf_tmp_(L), STRFMT_D, (uint64_t)intV47(o));
  } else if (tvisint(o)) {
    sb = lj_strfmt_putint(lj_buf_tmp_(L), intV(o));
  } else if (tvisi64(o)) {
    /* ADR-001b: print's shortcut path must know the boxed integer. */
    sb = lj_strfmt_putfxint(lj_buf_tmp_(L), STRFMT_D, (uint64_t)i64V(o));
  } else if (tvisnum(o)) {
    sb = lj_strfmt_putfnumstr(lj_buf_tmp_(L), o->n);
  } else {
    return NULL;
  }
  *lenp = sbuflen(sb);
  return sb->b;
}

/* -- Unformatted conversions to buffer ----------------------------------- */

/* Add integer to buffer. */
SBuf * LJ_FASTCALL lj_strfmt_putint(SBuf *sb, int32_t k)
{
  sb->w = lj_strfmt_wint(lj_buf_more(sb, STRFMT_MAXBUF_INT), k);
  return sb;
}

#if LJ_HASJIT
/* Add number to buffer. */
SBuf * LJ_FASTCALL lj_strfmt_putnum(SBuf *sb, cTValue *o)
{
  return lj_strfmt_putfnumstr(sb, o->n);
}
#endif

/* Lua 5.4 number->string for tostring/concat: %.14g, but a rendering that
** looks like an integer gets a ".0" suffix (tostring(3.0) == "3.0"). */
SBuf * LJ_FASTCALL lj_strfmt_putfnumstr(SBuf *sb, lua_Number n)
{
  MSize ofs = sbuflen(sb);  /* Offset, not pointer: putnum may reallocate. */
  MSize len, i;
  sb = lj_strfmt_putfnum(sb, STRFMT_G14, n);
  len = sbuflen(sb) - ofs;
  i = 0;
  while (i < len &&
	 (sb->b[ofs+i] == '-' || (sb->b[ofs+i] >= '0' && sb->b[ofs+i] <= '9')))
    i++;
  if (i == len) {
    char *w = lj_buf_more(sb, 2);
    w[0] = '.';
    w[1] = '0';
    sb->w = w + 2;
  }
  return sb;
}

SBuf * LJ_FASTCALL lj_strfmt_putptr(SBuf *sb, const void *v)
{
  sb->w = lj_strfmt_wptr(lj_buf_more(sb, STRFMT_MAXBUF_PTR), v);
  return sb;
}

/* Add quoted string to buffer. */
static SBuf *strfmt_putquotedlen(SBuf *sb, const char *s, MSize len)
{
  lj_buf_putb(sb, '"');
  while (len--) {
    uint32_t c = (uint32_t)(uint8_t)*s++;
    char *w = lj_buf_more(sb, 4);
    if (c == '"' || c == '\\' || c == '\n') {
      *w++ = '\\';
    } else if (lj_char_iscntrl(c)) {  /* This can only be 0-31 or 127. */
      uint32_t d;
      *w++ = '\\';
      if (c >= 100 || lj_char_isdigit((uint8_t)*s)) {
	*w++ = (char)('0'+(c >= 100)); if (c >= 100) c -= 100;
	goto tens;
      } else if (c >= 10) {
      tens:
	d = (c * 205) >> 11; c -= d * 10; *w++ = (char)('0'+d);
      }
      c += '0';
    }
    *w++ = (char)c;
    sb->w = w;
  }
  lj_buf_putb(sb, '"');
  return sb;
}

#if LJ_HASJIT
SBuf * LJ_FASTCALL lj_strfmt_putquoted(SBuf *sb, GCstr *str)
{
  return strfmt_putquotedlen(sb, strdata(str), str->len);
}
#endif

/* -- Formatted conversions to buffer ------------------------------------- */

/* Add formatted char to buffer. */
SBuf *lj_strfmt_putfchar(SBuf *sb, SFormat sf, int32_t c)
{
  MSize width = STRFMT_WIDTH(sf);
  char *w = lj_buf_more(sb, width > 1 ? width : 1);
  if ((sf & STRFMT_F_LEFT)) *w++ = (char)c;
  while (width-- > 1) *w++ = ' ';
  if (!(sf & STRFMT_F_LEFT)) *w++ = (char)c;
  sb->w = w;
  return sb;
}

/* Add formatted string to buffer. */
static SBuf *strfmt_putfstrlen(SBuf *sb, SFormat sf, const char *s, MSize len)
{
  MSize width = STRFMT_WIDTH(sf);
  char *w;
  if (len > STRFMT_PREC(sf)) len = STRFMT_PREC(sf);
  w = lj_buf_more(sb, width > len ? width : len);
  if ((sf & STRFMT_F_LEFT)) w = lj_buf_wmem(w, s, len);
  while (width-- > len) *w++ = ' ';
  if (!(sf & STRFMT_F_LEFT)) w = lj_buf_wmem(w, s, len);
  sb->w = w;
  return sb;
}

#if LJ_HASJIT
SBuf *lj_strfmt_putfstr(SBuf *sb, SFormat sf, GCstr *str)
{
  return strfmt_putfstrlen(sb, sf, strdata(str), str->len);
}
#endif

/* Add formatted signed/unsigned integer to buffer. */
SBuf *lj_strfmt_putfxint(SBuf *sb, SFormat sf, uint64_t k)
{
  char buf[STRFMT_MAXBUF_XINT], *q = buf + sizeof(buf), *w;
#ifdef LUA_USE_ASSERT
  char *ws;
#endif
  MSize prefix = 0, len, prec, pprec, width, need;

  /* Figure out signed prefixes. */
  if (STRFMT_TYPE(sf) == STRFMT_INT) {
    if ((int64_t)k < 0) {
      k = ~k+1u;
      prefix = 256 + '-';
    } else if ((sf & STRFMT_F_PLUS)) {
      prefix = 256 + '+';
    } else if ((sf & STRFMT_F_SPACE)) {
      prefix = 256 + ' ';
    }
  }

  /* Convert number and store to fixed-size buffer in reverse order. */
  prec = STRFMT_PREC(sf);
  if ((int32_t)prec >= 0) sf &= ~STRFMT_F_ZERO;
  if (k == 0) {  /* Special-case zero argument. */
    if (prec != 0 ||
	(sf & (STRFMT_T_OCT|STRFMT_F_ALT)) == (STRFMT_T_OCT|STRFMT_F_ALT))
      *--q = '0';
  } else if (!(sf & (STRFMT_T_HEX|STRFMT_T_OCT))) {  /* Decimal. */
    uint32_t k2;
    while ((k >> 32)) { *--q = (char)('0' + k % 10); k /= 10; }
    k2 = (uint32_t)k;
    do { *--q = (char)('0' + k2 % 10); k2 /= 10; } while (k2);
  } else if ((sf & STRFMT_T_HEX)) {  /* Hex. */
    const char *hexdig = (sf & STRFMT_F_UPPER) ? "0123456789ABCDEF" :
						 "0123456789abcdef";
    do { *--q = hexdig[(k & 15)]; k >>= 4; } while (k);
    if ((sf & STRFMT_F_ALT)) prefix = 512 + ((sf & STRFMT_F_UPPER) ? 'X' : 'x');
  } else {  /* Octal. */
    do { *--q = (char)('0' + (uint32_t)(k & 7)); k >>= 3; } while (k);
    if ((sf & STRFMT_F_ALT)) *--q = '0';
  }

  /* Calculate sizes. */
  len = (MSize)(buf + sizeof(buf) - q);
  if ((int32_t)len >= (int32_t)prec) prec = len;
  width = STRFMT_WIDTH(sf);
  pprec = prec + (prefix >> 8);
  need = width > pprec ? width : pprec;
  w = lj_buf_more(sb, need);
#ifdef LUA_USE_ASSERT
  ws = w;
#endif

  /* Format number with leading/trailing whitespace and zeros. */
  if ((sf & (STRFMT_F_LEFT|STRFMT_F_ZERO)) == 0)
    while (width-- > pprec) *w++ = ' ';
  if (prefix) {
    if ((char)prefix >= 'X') *w++ = '0';
    *w++ = (char)prefix;
  }
  if ((sf & (STRFMT_F_LEFT|STRFMT_F_ZERO)) == STRFMT_F_ZERO)
    while (width-- > pprec) *w++ = '0';
  while (prec-- > len) *w++ = '0';
  while (q < buf + sizeof(buf)) *w++ = *q++;  /* Add number itself. */
  if ((sf & STRFMT_F_LEFT))
    while (width-- > pprec) *w++ = ' ';

  lj_assertX(need == (MSize)(w - ws), "miscalculated format size");
  sb->w = w;
  return sb;
}

/* Add number formatted as signed integer to buffer. */
SBuf *lj_strfmt_putfnum_int(SBuf *sb, SFormat sf, lua_Number n)
{
  int64_t k = lj_num2i64(n);
  if (checki32(k) && sf == STRFMT_INT)
    return lj_strfmt_putint(sb, (int32_t)k);  /* Shortcut for plain %d. */
  else
    return lj_strfmt_putfxint(sb, sf, (uint64_t)k);
}

/* 5.4: %d/%i/%u/%x/%X/%o require an exact integer representation. */
static void strfmt_checkint(lua_State *L, int arg, lua_Number n)
{
  int64_t k = lj_num2i64(n);
  /* The conversion saturates on some targets: check the range explicitly. */
  if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0) ||
      (lua_Number)k != n)
    lj_err_arg(L, arg, LJ_ERR_NUMNOINT);
}

/* Add number formatted as unsigned integer to buffer. */
SBuf *lj_strfmt_putfnum_uint(SBuf *sb, SFormat sf, lua_Number n)
{
  return lj_strfmt_putfxint(sb, sf, lj_num2u64(n));
}

/* Format stack arguments to buffer. */
/* True unless the string metatable is known to have no __tostring. */
static LJ_AINLINE int strfmt_strmm(lua_State *L)
{
  GCtab *mt = tabref(basemt_it(G(L), LJ_TSTR));
  return mt && !(mt->nomm & MM_TOSTR_ABSENT);
}

int lj_strfmt_putarg(lua_State *L, SBuf *sb, int arg, int retry)
{
  int narg = (int)(L->top - L->base);
  GCstr *fmt = lj_lib_checkstr(L, arg);
  FormatState fs;
  SFormat sf;
  lj_strfmt_init(&fs, strdata(fmt), fmt->len);
  while ((sf = lj_strfmt_parse(&fs)) != STRFMT_EOF) {
    if (sf == STRFMT_LIT) {
      lj_buf_putmem(sb, fs.str, fs.len);
    } else if (sf == STRFMT_ERR) {
      lj_err_callerv(L, LJ_ERR_STRFMT,
		     strdata(lj_str_new(L, fs.str, fs.len)));
    } else {
      TValue *o = &L->base[arg++];
      if (arg > narg)
	lj_err_arg(L, arg, LJ_ERR_NOVAL);
      switch (STRFMT_TYPE(sf)) {
      case STRFMT_INT:
	if (tvisi64(o)) {
	  lj_strfmt_putfxint(sb, sf, (uint64_t)i64V(o));
	  break;
	}
	if (tvisi47w(o)) {
	  lj_strfmt_putfxint(sb, sf, (uint64_t)intV47(o));
	  break;
	}
	if (tvisint(o)) {
	  int32_t k = intV(o);
	  if (sf == STRFMT_INT)
	    lj_strfmt_putint(sb, k);  /* Shortcut for plain %d. */
	  else
	    lj_strfmt_putfxint(sb, sf, k);
	  break;
	}
#if LJ_HASFFI
	if (tviscdata(o)) {
	  GCcdata *cd = cdataV(o);
	  if (cd->ctypeid == CTID_INT64 || cd->ctypeid == CTID_UINT64) {
	    lj_strfmt_putfxint(sb, sf, *(uint64_t *)cdataptr(cd));
	    break;
	  }
	}
#endif
	{
	  lua_Number n = lj_lib_checknum(L, arg);
	  strfmt_checkint(L, arg, n);
	  lj_strfmt_putfnum_int(sb, sf, n);
	}
	break;
      case STRFMT_UINT:
	if (tvisi64(o)) {
	  lj_strfmt_putfxint(sb, sf, (uint64_t)i64V(o));
	  break;
	}
	if (tvisi47w(o)) {
	  lj_strfmt_putfxint(sb, sf, (uint64_t)intV47(o));
	  break;
	}
	if (tvisint(o)) {
	  lj_strfmt_putfxint(sb, sf, intV(o));
	  break;
	}
#if LJ_HASFFI
	if (tviscdata(o)) {
	  GCcdata *cd = cdataV(o);
	  if (cd->ctypeid == CTID_INT64 || cd->ctypeid == CTID_UINT64) {
	    lj_strfmt_putfxint(sb, sf, *(uint64_t *)cdataptr(cd));
	    break;
	  }
	}
#endif
	{
	  lua_Number n = lj_lib_checknum(L, arg);
	  strfmt_checkint(L, arg, n);
	  lj_strfmt_putfnum_uint(sb, sf, n);
	}
	break;
      case STRFMT_NUM:
	lj_strfmt_putfnum(sb, sf, lj_lib_checknum(L, arg));
	break;
      case STRFMT_STR: {
	MSize len;
	const char *s;
	cTValue *mo;
	if ((sf & STRFMT_T_QUOTED) && !tvisstr(o) && !tvisbuf(o)) {
	  /* 5.4: %q renders numbers, nil and booleans as readable literals. */
	  if (tvisi47w(o) || tvisi64(o)) {  /* 5.4 integer outside int32. */
	    int64_t v = tvisi64(o) ? i64V(o) : intV47(o);
	    if (v == (int64_t)(-0x7fffffffffffffffLL - 1))  /* lstrlib: mininteger as hex. */
	      sb = lj_buf_putmem(sb, "0x8000000000000000", 18);
	    else
	      sb = lj_strfmt_putfxint(sb, STRFMT_D, (uint64_t)v);
	    break;
	  } else if (tvisint(o)) {
	    sb = lj_strfmt_putint(sb, intV(o));
	    break;
	  } else if (tvisnum(o)) {
	    if (o->u64 == U64x(7ff00000,00000000)) {
	      sb = lj_buf_putmem(sb, "1e9999", 6);
	    } else if (o->u64 == U64x(fff00000,00000000)) {
	      sb = lj_buf_putmem(sb, "-1e9999", 7);
	    } else if (tvisnan(o)) {
	      sb = lj_buf_putmem(sb, "(0/0)", 5);
	    } else {
	      sb = lj_strfmt_putfnum(sb, STRFMT_A, numV(o));  /* exact hex float */
	    }
	    break;
	  } else if (tvisnil(o) || tvisbool(o)) {
	    GCstr *str = lj_strfmt_obj(L, o);
	    sb = lj_buf_putmem(sb, strdata(str), str->len);
	    break;
	  } else {
	    lj_err_arg(L, arg, LJ_ERR_NOLITERAL);
	  }
	}
	/* 5.4 luaL_tolstring: %s calls __tostring for every value, a string
	** included when the string metatable has the method (%q does not).
	** The negative cache bit keeps a plain string to one test. */
	if (LJ_UNLIKELY(tvisstr(o) ? (!(sf & STRFMT_T_QUOTED) && strfmt_strmm(L)) :
				     !tvisbuf(o)) && retry >= 0 &&
	    !tvisnil(mo = lj_meta_lookup(L, o, MM_tostring))) {
	  /* Call __tostring metamethod once. */
	  copyTV(L, L->top++, mo);
	  copyTV(L, L->top++, o);
	  lua_call(L, 1, 1);
	  o = &L->base[arg-1];  /* The stack may have been reallocated. */
	  lj_strfmt_tolstrres(L);  /* 5.4: string or number, else raise. */
	  copyTV(L, o, L->top-1);  /* Replace inline for retry (now a string). */
	  L->top--;
	  if (retry < 2) {  /* Global buffer may have been overwritten. */
	    retry = 1;
	    break;
	  }
	}
	if (LJ_LIKELY(tvisstr(o))) {
	  len = strV(o)->len;
	  s = strVdata(o);
#if LJ_HASBUFFER
	} else if (tvisbuf(o)) {
	  SBufExt *sbx = bufV(o);
	  if (sbx == (SBufExt *)sb) lj_err_arg(L, arg+1, LJ_ERR_BUFFER_SELF);
	  len = sbufxlen(sbx);
	  s = sbx->r;
#endif
	} else {
	  GCstr *str = lj_strfmt_obj(L, o);
	  len = str->len;
	  s = strdata(str);
	}
	if ((sf & STRFMT_T_QUOTED))
	  strfmt_putquotedlen(sb, s, len);  /* No formatting. */
	else
	  strfmt_putfstrlen(sb, sf, s, len);
	break;
	}
      case STRFMT_CHAR:
	lj_strfmt_putfchar(sb, sf, lj_lib_checkint(L, arg));
	break;
      case STRFMT_PTR:  /* No formatting. */
	lj_strfmt_putptr(sb, lj_obj_ptr(G(L), o));
	break;
      default:
	lj_assertL(0, "bad string format type");
	break;
      }
    }
  }
  return retry;
}

/* -- Conversions to strings ---------------------------------------------- */

/* Convert integer to string. */
GCstr * LJ_FASTCALL lj_strfmt_int(lua_State *L, int32_t k)
{
  char buf[STRFMT_MAXBUF_INT];
  MSize len = (MSize)(lj_strfmt_wint(buf, k) - buf);
  return lj_str_new(L, buf, len);
}

/* Boxed int64 (ADR-001b): write the decimal form into a plain buffer. No SBuf
** here: lj_strfmt_putfxint() may grow the buffer, which a stack SBuf cannot. */
static char *strfmt_wint64(char *p, int64_t k)
{
  char tmp[22];
  int n = 0;
  uint64_t u = k < 0 ? (uint64_t)0 - (uint64_t)k : (uint64_t)k;
  do {
    tmp[n++] = (char)('0' + (u % 10));
    u /= 10;
  } while (u != 0);
  if (k < 0) *p++ = '-';
  while (n > 0) *p++ = tmp[--n];
  return p;
}

GCstr * LJ_FASTCALL lj_strfmt_i64(lua_State *L, int64_t k)
{
  char buf[22];
  char *p = strfmt_wint64(buf, k);
  return lj_str_new(L, buf, (MSize)(p - buf));
}

/* Convert integer or number to string. */
GCstr * LJ_FASTCALL lj_strfmt_number(lua_State *L, cTValue *o)
{
  if (tvisi64(o)) return lj_strfmt_i64(L, i64V(o));
  if (tvisi47w(o)) return lj_strfmt_i64(L, intV47(o));
  return tvisint(o) ? lj_strfmt_int(L, intV(o)) : lj_strfmt_num(L, o);
}

#if LJ_HASJIT
/* Convert char value to string. */
GCstr * LJ_FASTCALL lj_strfmt_char(lua_State *L, int c)
{
  char buf[1];
  buf[0] = c;
  return lj_str_new(L, buf, 1);
}
#endif

/* 5.4 luaL_tolstring: a metatable's string __name names an object without a
** __tostring. Look it up like lj_meta_lookup does, so per-type base
** metatables (function, thread, light userdata) work too. */
static GCstr *strfmt_objname(lua_State *L, cTValue *o)
{
  GCtab *mt;
  if (tvistab(o))
    mt = tabref(tabV(o)->metatable);
  else if (tvisudata(o) && !tvisi64(o))  /* boxed int64 is a number */
    mt = tabref(udataV(o)->metatable);
  else
    mt = tabref(basemt_obj(G(L), o));
  if (mt) {
    cTValue *tv = lj_tab_getstr(mt, lj_str_newlit(L, "__name"));
    if (tv && tvisstr(tv)) return strV(tv);
  }
  return NULL;
}

#define STRFMT_OBJBUF	(8+2+2+16)

/* Raw conversion of object to string. */
GCstr * LJ_FASTCALL lj_strfmt_obj(lua_State *L, cTValue *o)
{
  if (tvisstr(o)) {
    return strV(o);
  } else if (tvisnumber(o)) {
    return lj_strfmt_number(L, o);
  } else if (tvisi64(o)) {
    return lj_strfmt_i64(L, i64V(o));
  } else if (tvisnil(o)) {
    return lj_str_newlit(L, "nil");
  } else if (tvisfalse(o)) {
    return lj_str_newlit(L, "false");
  } else if (tvistrue(o)) {
    return lj_str_newlit(L, "true");
  } else {
    GCstr *name = strfmt_objname(L, o);
    const char *kind = name ? strdata(name) : lj_typename(o);
    MSize klen = name ? name->len : (MSize)strlen(kind);
    char tail[2+STRFMT_MAXBUF_PTR], *tp = tail;
    MSize tlen;
    *tp++ = ':'; *tp++ = ' ';
    if (tvisfunc(o) && isffunc(funcV(o))) {
      tp = lj_buf_wmem(tp, "builtin#", 8);
      tp = lj_strfmt_wint(tp, funcV(o)->c.ffid);
    } else {
      tp = lj_strfmt_wptr(tp, lj_obj_ptr(G(L), o));
    }
    tlen = (MSize)(tp - tail);
    if (klen + tlen <= STRFMT_OBJBUF) {
      char buf[STRFMT_OBJBUF];
      memcpy(buf, kind, klen);
      memcpy(buf+klen, tail, tlen);
      return lj_str_new(L, buf, klen+tlen);
    } else {  /* Long __name: build in a heap buffer, not the global one. */
      SBuf sb;
      GCstr *s;
      lj_buf_init(L, &sb);
      lj_buf_putmem(&sb, kind, klen);
      lj_buf_putmem(&sb, tail, tlen);
      s = lj_buf_str(L, &sb);
      lj_buf_free(G(L), &sb);
      return s;
    }
  }
}

/* 5.4 rule for a __tostring result (luaL_tolstring): a string is used as is, a
** number is converted, anything else raises. The result is at L->top-1 and is
** replaced by the string it stands for. Buffers are userdata in LuaJIT and,
** like in lua_isstring, not strings for this check. */
GCstr * LJ_FASTCALL lj_strfmt_tolstrres(lua_State *L)
{
  TValue *o = L->top-1;
  if (tvisstr(o)) return strV(o);
  if (tvisnumber(o) || tvisi64(o)) {
    GCstr *s;
    lj_gc_check(L);
    s = lj_strfmt_obj(L, L->top-1);
    setstrV(L, L->top-1, s);
    return s;
  }
  lj_err_caller(L, LJ_ERR_TOLSTR);
  return NULL;  /* unreachable */
}

/* -- Internal string formatting ------------------------------------------ */

/*
** These functions are only used for lua_pushfstring(), lua_pushvfstring()
** and for internal string formatting (e.g. error messages). Caveat: unlike
** string.format(), only a limited subset of formats and flags are supported!
**
** LuaJIT has support for a couple more formats than Lua 5.1/5.2:
** - %d %u %o %x with full formatting, 32 bit integers only.
** - %f and other FP formats are really %.14g.
** - %s %c %p without formatting.
*/

/* Push formatted message as a string object to Lua stack. va_list variant. */
const char *lj_strfmt_pushvf(lua_State *L, const char *fmt, va_list argp)
{
  SBuf *sb = lj_buf_tmp_(L);
  FormatState fs;
  SFormat sf;
  GCstr *str;
  lj_strfmt_init(&fs, fmt, (MSize)strlen(fmt));
  while ((sf = lj_strfmt_parse(&fs)) != STRFMT_EOF) {
    switch (STRFMT_TYPE(sf)) {
    case STRFMT_LIT:
      lj_buf_putmem(sb, fs.str, fs.len);
      break;
    case STRFMT_INT:
      lj_strfmt_putfxint(sb, sf, va_arg(argp, int32_t));
      break;
    case STRFMT_UINT:
      lj_strfmt_putfxint(sb, sf, va_arg(argp, uint32_t));
      break;
    case STRFMT_NUM:
      lj_strfmt_putfnum(sb, STRFMT_G14, va_arg(argp, lua_Number));
      break;
    case STRFMT_STR: {
      const char *s = va_arg(argp, char *);
      if (s == NULL) s = "(null)";
      lj_buf_putmem(sb, s, (MSize)strlen(s));
      break;
      }
    case STRFMT_CHAR:
      lj_buf_putb(sb, va_arg(argp, int));
      break;
    case STRFMT_PTR:
      lj_strfmt_putptr(sb, va_arg(argp, void *));
      break;
    case STRFMT_ERR:
    default:
      lj_buf_putb(sb, '?');
      lj_assertL(0, "bad string format near offset %d", fs.len);
      break;
    }
  }
  str = lj_buf_str(L, sb);
  setstrV(L, L->top, str);
  incr_top(L);
  return strdata(str);
}

/* Push formatted message as a string object to Lua stack. Vararg variant. */
const char *lj_strfmt_pushf(lua_State *L, const char *fmt, ...)
{
  const char *msg;
  va_list argp;
  va_start(argp, fmt);
  msg = lj_strfmt_pushvf(L, fmt, argp);
  va_end(argp);
  return msg;
}

