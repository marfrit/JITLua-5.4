/*
** Lexical analyzer.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
*/

#ifndef _LJ_LEX_H
#define _LJ_LEX_H

#include <stdarg.h>

#include "lj_obj.h"
#include "lj_err.h"

/* Lua lexer tokens. */
#define TKDEF(_, __) \
  _(and) _(break) _(const) _(continue) _(do) _(else) _(elseif) _(end) _(false) \
  _(for) _(function) _(goto) _(if) _(in) _(local) _(nil) _(not) _(or) \
  _(repeat) _(return) _(then) _(true) _(until) _(while) \
  __(concat, ..) __(dots, ...) __(eq, ==) __(ge, >=) __(le, <=) __(ne, ~=) \
  __(nav, ?.) __(coal, \?\?) __(shl, <<) __(shr, >>)  __(sar, ~>>) \
  __(and_, &&) __(or_, ||) __(ne_, !=) __(arrow, ->) \
  __(label, ::) __(number, <number>) __(name, <name>) __(string, <string>) \
  __(eof, <eof>)

enum {
  TK_OFS = 256,
#define TKENUM1(name)		TK_##name,
#define TKENUM2(name, sym)	TK_##name,
TKDEF(TKENUM1, TKENUM2)
#undef TKENUM1
#undef TKENUM2
  TK_RESERVED = TK_while - TK_OFS
};

typedef int LexChar;	/* Lexical character. Unsigned ext. from char. */
typedef int LexToken;	/* Lexical token. */

/* Lua 5.4 floor-division token '//'. It cannot live in TKDEF because "//" would
** start a C comment inside the macro argument; the token name only shows up in
** syntax-error text, so a private code is fine. */
#define TK_idiv		253

/* Combined bytecode ins/line. Only used during bytecode generation. */
typedef struct BCInsLine {
  BCIns ins;		/* Bytecode instruction. */
  BCLine line;		/* Line number for this bytecode. */
} BCInsLine;

/* Index into variable stack. 32 bit: the locals, labels and gotos of all
** functions being parsed share the stack (5.4 has no limit across them). */
typedef uint32_t VarIndex;

#define LJ_VINDEX_HSIZE	32	/* Hash table size. Must be a power of 2. */
#define LJ_VINDEX_MASK	(LJ_VINDEX_HSIZE-1)

/* Info for local variables. Only used during bytecode generation. */
typedef struct VarInfo {
  GCRef name;		/* Local variable name or goto/label name. */
  BCPos startpc;	/* First point where the local variable is active. */
  BCPos endpc;		/* First point where the local variable is dead. */
  BCLine line;		/* Definition line (labels: for 5.4 duplicate diagnostics). */
  uint8_t slot;		/* Variable slot. */
  uint8_t info;		/* Variable/goto/label info. */
  uint16_t ord;		/* Locals: declaration number within the function. */
  VarIndex prev;	/* Previous entry in variable hash chain. */
} VarInfo;

/* Lua lexer state. */
typedef struct LexState {
  struct FuncState *fs;	/* Current FuncState. Defined in lj_parse.c. */
  struct lua_State *L;	/* Lua state. */
  TValue tokval;	/* Current token value. */
  TValue lookaheadval;	/* Lookahead token value. */
  const char *p;	/* Current position in input buffer. */
  const char *pe;	/* End of input buffer. */
  LexChar c;		/* Current character. */
  LexToken tok;		/* Current token. */
  LexToken lookahead;	/* Lookahead token. */
  SBuf sb;		/* String buffer for tokens. */
  lua_Reader rfunc;	/* Reader callback. */
  void *rdata;		/* Reader callback data. */
  BCLine linenumber;	/* Input line counter. */
  BCLine lastline;	/* Line of last token. */
  GCstr *chunkname;	/* Current chunk name (interned string). */
  ptrdiff_t chunkslot;	/* Stack slot anchoring the chunk name. */
  const char *chunkarg;	/* Chunk name argument. */
  const char *mode;	/* Allow loading bytecode (b) and/or source text (t). */
  VarInfo *vstack;	/* Stack for names and extents of local variables. */
  MSize sizevstack;	/* Size of variable stack. */
  MSize vtop;		/* Top of variable stack. */
  VarIndex *vlocal;	/* Variable stack index of each declared local. */
  MSize sizevlocal;	/* Size of vlocal. */
  MSize nvlocal;	/* Top of vlocal. */
  BCInsLine *bcstack;	/* Stack for bytecode instructions/line numbers. */
  MSize sizebcstack;	/* Size of bytecode stack. */
  uint32_t level;	/* Syntactical nesting level. */
  MSize nlabel;		/* 5.4: visible labels (PUC dyd->label). */
  MSize ngoto;		/* 5.4: pending forward gotos and breaks (dyd->gt). */
  int endmark;		/* Trust bytecode end marker, even if not at EOF. */
  int fr2;		/* Generate bytecode for LJ_FR2 mode. */
  VarIndex vhash[LJ_VINDEX_HSIZE];	/* Variable hash chain anchors. */
} LexState;

LJ_FUNC int lj_lex_setup(lua_State *L, LexState *ls);
LJ_FUNC void lj_lex_cleanup(lua_State *L, LexState *ls);
LJ_FUNC void lj_lex_next(LexState *ls);
LJ_FUNC LexToken lj_lex_lookahead(LexState *ls);
LJ_FUNC const char *lj_lex_token2str(LexState *ls, LexToken tok);
LJ_FUNC_NORET void lj_lex_error(LexState *ls, LexToken tok, ErrMsg em, ...);
LJ_FUNC void lj_lex_init(lua_State *L);

#ifdef LUA_USE_ASSERT
#define lj_assertLS(c, ...)	(lj_assertG_(G(ls->L), (c), __VA_ARGS__))
#else
#define lj_assertLS(c, ...)	((void)ls)
#endif

#endif
