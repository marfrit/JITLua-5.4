/*
** Garbage collector.
** Copyright (C) 2005-2026 Mike Pall. See Copyright Notice in luajit.h
**
** Major portions taken verbatim or adapted from the Lua interpreter.
** Copyright (C) 1994-2008 Lua.org, PUC-Rio. See Copyright Notice in lua.h
*/

#define lj_gc_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_err.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_tab.h"
#include "lj_func.h"
#include "lj_udata.h"
#include "lj_i64.h"
#include "lj_meta.h"
#include "lj_state.h"
#include "lj_frame.h"
#include "lj_bc.h"
#if LJ_HASFFI
#include "lj_ctype.h"
#include "lj_cdata.h"
#endif
#include "lj_trace.h"
#include "lj_dispatch.h"
#include "lj_vm.h"
#include "lj_vmevent.h"

/* Optional GC pause instrumentation (measurement builds only). Compile with
** -DLUAJIT_GC_STATS. Nothing below is compiled in a default build.
**
** Stage 0(b) adds a per-phase split of collector time: every gc_onestep()
** case is timed, so the phase totals sum to the incremental step total (plus
** any explicit collectgarbage("collect") work, which lj_gc_fullgc drives
** outside the lj_gc_step() timer). The allocation path is counted, and its
** allocator time is timed on a 1-in-64 sample so the probes cannot dominate a
** churn workload.
*/
#ifdef LUAJIT_GC_STATS
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>

#define GCSTATS_ALLOC_SAMPLE	6  /* Time 1 call in (1<<6) = 64. */

typedef struct GCStats {
  uint64_t steps, cycles, fullgc, atomic_calls;
  uint64_t step_ns, step_max_ns, full_ns, full_max_ns;
  uint64_t atomic_ns, atomic_max_ns;
  /* Per-phase split (Stage 0b). atomic_ns is the atomic phase. */
  uint64_t mark_ns, mark_steps, mark_runs;   /* GCSpause + GCSpropagate */
  uint64_t sweepstr_ns, sweepstr_steps, sweepstr_runs;
  uint64_t sweep_ns, sweep_steps, sweep_runs;
  uint64_t finalize_ns, finalize_steps, finalize_runs;
  /* Allocation path (mutator context; free() nests inside sweep). */
  uint64_t alloc_calls, alloc_bytes, free_calls, free_bytes;
  uint64_t alloc_ns, alloc_samples;
  uint32_t step_hist[64], full_hist[64], atomic_hist[64];
} GCStats;

static GCStats gcstats;
static uint32_t gcstats_alloc_tick;

/* Allocation sampler: GCSTATS_ALLOC_OPEN() before the allocf() call,
** GCSTATS_ALLOC_CLOSE() after it. Times 1 call in (1<<GCSTATS_ALLOC_SAMPLE). */
#define GCSTATS_ALLOC_OPEN() \
  int _gcstats_time = ((gcstats_alloc_tick++ & ((1u<<GCSTATS_ALLOC_SAMPLE)-1)) == 0); \
  uint64_t _gcstats_a0 = _gcstats_time ? gcstats_now() : 0
#define GCSTATS_ALLOC_CLOSE() do { \
  if (_gcstats_time) { \
    gcstats.alloc_ns += gcstats_now() - _gcstats_a0; gcstats.alloc_samples++; \
  } \
} while (0)

static uint64_t gcstats_now(void)
{
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull;
}

/* Cost of one gcstats_now() call, measured at exit. Every timed interval in
** this file contains one such call (the interval starts and ends at a clock
** read), so the dump subtracts steps*clock to report body time, not probe
** time. The probe is ~25 ns against mark/sweep bodies of ~80 ns to ~1 us, so
** without this the split would be biased towards the phase with more steps. */
static uint64_t gcstats_clock_ns;
static uint64_t gcstats_calib_sink;

static void gcstats_calibrate(void)
{
  int i;
  uint64_t t0, t1, s = 0;
  t0 = gcstats_now();
  for (i = 0; i < 20000; i++) s += gcstats_now();
  t1 = gcstats_now();
  gcstats_calib_sink = s;
  (void)gcstats_calib_sink;
  gcstats_clock_ns = (t1 - t0) / 20001u;
}

/* Attribute a completed phase run to its phase. GCSatomic is skipped: it has
** its own timer below, so the atomic phase is not double-counted. */
static void gcstats_phase_add(int st, uint64_t dt)
{
  switch (st) {
  case GCSpause: case GCSpropagate:
    gcstats.mark_ns += dt; gcstats.mark_runs++; break;
  case GCSatomic:
    break;
  case GCSsweepstring:
    gcstats.sweepstr_ns += dt; gcstats.sweepstr_runs++; break;
  case GCSsweep:
    gcstats.sweep_ns += dt; gcstats.sweep_runs++; break;
  case GCSfinalize:
    gcstats.finalize_ns += dt; gcstats.finalize_runs++; break;
  default:
    break;
  }
}

/* Phase-run timer. The collector runs in bursts (lj_gc_step / lj_gc_fullgc),
** and a phase can span many bursts with mutator time in between, so the timer
** is opened when a burst starts, closed when it ends, and closed+reopened when
** the state changes inside a burst. That is ~2 clock reads per state change
**(a few hundred per run), not per step, so the probe cost is negligible and
** the split is not biased towards the phase with more steps. */
static uint8_t gcstats_run;
static uint8_t gcstats_phase_state;
static uint64_t gcstats_phase_start;

static void gcstats_resume(global_State *g)
{
  gcstats_run = 1;
  gcstats_phase_state = (uint8_t)g->gc.state;
  gcstats_phase_start = gcstats_now();
}

static void gcstats_pause(void)
{
  if (gcstats_run) {
    gcstats_phase_add(gcstats_phase_state, gcstats_now() - gcstats_phase_start);
    gcstats_run = 0;
  }
}

static void gcstats_switch(global_State *g)
{
  uint64_t now = gcstats_now();
  gcstats_phase_add(gcstats_phase_state, now - gcstats_phase_start);
  gcstats_phase_state = (uint8_t)g->gc.state;
  gcstats_phase_start = now;
}

/* Count one gc_onestep() in its entry phase (no clock read). */
static void gcstats_step_count(int st)
{
  switch (st) {
  case GCSpause: case GCSpropagate: gcstats.mark_steps++; break;
  case GCSsweepstring: gcstats.sweepstr_steps++; break;
  case GCSsweep: gcstats.sweep_steps++; break;
  case GCSfinalize: gcstats.finalize_steps++; break;
  default: break;
  }
}

/* ns -> us, minus the per-sample clock-probe overhead (allocation sampler). */
static double gcstats_net_us(uint64_t ns, uint64_t nsamples)
{
  uint64_t oh = gcstats_clock_ns * nsamples;
  return (double)(ns > oh ? ns - oh : 0) / 1000.0;
}

/* Log2 histogram: bucket b holds durations in [2^b, 2^(b+1)) nanoseconds. */
static void gcstats_add(uint32_t *hist, uint64_t ns)
{
  int b = 0;
  if (ns == 0) ns = 1;
  while (ns > 1 && b < 63) { ns >>= 1; b++; }
  hist[b]++;
}

static double gcstats_pct(const uint32_t *hist, uint64_t total, double p)
{
  uint64_t want, cum = 0;
  int b;
  if (total == 0) return 0.0;
  want = (uint64_t)(p * (double)total);
  if (want == 0) want = 1;
  for (b = 0; b < 64; b++) {
    cum += hist[b];
    if (cum >= want) return (double)(1ull << (b + 1)) / 1000.0;
  }
  return 0.0;
}

static void __attribute__((destructor)) gcstats_dump(void)
{
  gcstats_calibrate();
  fprintf(stderr,
    "GCSTATS steps=%llu cycles=%llu full=%llu atomic=%llu "
    "step_total_us=%.3f step_p50_us=%.3f step_p99_us=%.3f step_max_us=%.3f "
    "full_total_us=%.3f full_p99_us=%.3f full_max_us=%.3f "
    "atomic_total_us=%.3f atomic_p50_us=%.3f atomic_p99_us=%.3f atomic_max_us=%.3f "
    "phase_mark_us=%.3f phase_mark_steps=%llu phase_mark_runs=%llu "
    "phase_atomic_us=%.3f "
    "phase_sweepstr_us=%.3f phase_sweepstr_steps=%llu phase_sweepstr_runs=%llu "
    "phase_sweep_us=%.3f phase_sweep_steps=%llu phase_sweep_runs=%llu "
    "phase_finalize_us=%.3f phase_finalize_steps=%llu phase_finalize_runs=%llu "
    "phase_sum_us=%.3f clock_ns=%llu "
    "alloc_calls=%llu alloc_kb=%.3f free_calls=%llu free_kb=%.3f "
    "alloc_us=%.3f alloc_samples=%llu\n",
    (unsigned long long)gcstats.steps, (unsigned long long)gcstats.cycles,
    (unsigned long long)gcstats.fullgc, (unsigned long long)gcstats.atomic_calls,
    (double)gcstats.step_ns / 1000.0,
    gcstats_pct(gcstats.step_hist, gcstats.steps, 0.50),
    gcstats_pct(gcstats.step_hist, gcstats.steps, 0.99),
    (double)gcstats.step_max_ns / 1000.0,
    (double)gcstats.full_ns / 1000.0,
    gcstats_pct(gcstats.full_hist, gcstats.fullgc, 0.99),
    (double)gcstats.full_max_ns / 1000.0,
    (double)gcstats.atomic_ns / 1000.0,
    gcstats_pct(gcstats.atomic_hist, gcstats.atomic_calls, 0.50),
    gcstats_pct(gcstats.atomic_hist, gcstats.atomic_calls, 0.99),
    (double)gcstats.atomic_max_ns / 1000.0,
    (double)gcstats.mark_ns / 1000.0, (unsigned long long)gcstats.mark_steps,
    (unsigned long long)gcstats.mark_runs,
    (double)gcstats.atomic_ns / 1000.0,
    (double)gcstats.sweepstr_ns / 1000.0, (unsigned long long)gcstats.sweepstr_steps,
    (unsigned long long)gcstats.sweepstr_runs,
    (double)gcstats.sweep_ns / 1000.0, (unsigned long long)gcstats.sweep_steps,
    (unsigned long long)gcstats.sweep_runs,
    (double)gcstats.finalize_ns / 1000.0, (unsigned long long)gcstats.finalize_steps,
    (unsigned long long)gcstats.finalize_runs,
    (double)(gcstats.mark_ns + gcstats.atomic_ns + gcstats.sweepstr_ns +
             gcstats.sweep_ns + gcstats.finalize_ns) / 1000.0,
    (unsigned long long)gcstats_clock_ns,
    (unsigned long long)gcstats.alloc_calls, (double)gcstats.alloc_bytes / 1024.0,
    (unsigned long long)gcstats.free_calls, (double)gcstats.free_bytes / 1024.0,
    gcstats_net_us(gcstats.alloc_ns, gcstats.alloc_samples),
    (unsigned long long)gcstats.alloc_samples);
}

/* Count a free. Called from lj_mem_free (lj_gc.h); cheap, no timing. */
void lj_gc_stats_free(GCSize osz)
{
  gcstats.free_calls++; gcstats.free_bytes += osz;
}

/* Live-object census by GC type, printed when a GC cycle completes.  Strings
** live in the intern table, not on the root list, so they are walked there.
** Measurement only (LUAJIT_GC_STATS). */
static void gcstats_census(global_State *g)
{
  GCobj *o;
  uint64_t ntab = 0, nfunc = 0, nproto = 0, nudata = 0, nthr = 0, nother = 0;
  uint64_t tab_asize = 0, tab_hnodes = 0, tab_bytes = 0, str_bytes = 0;
  MSize i;
  for (o = gcref(g->gc.root); o != NULL; o = gcnext(o)) {
    switch (o->gch.gct) {
    case ~LJ_TTAB: {
      GCtab *t = gco2tab(o);
      uint64_t hn = t->hmask ? (uint64_t)t->hmask + 1 : 0;
      ntab++; tab_asize += t->asize; tab_hnodes += hn;
      tab_bytes += sizeof(GCtab) + (uint64_t)t->asize * sizeof(TValue) +
		   hn * sizeof(Node);
      break;
      }
    case ~LJ_TFUNC: nfunc++; break;
    case ~LJ_TPROTO: nproto++; break;
    case ~LJ_TUDATA: nudata++; break;
    case ~LJ_TTHREAD: nthr++; break;
    default: nother++; break;
    }
  }
  for (i = 0; i <= g->str.mask; i++) {
    GCobj *s = gcref(g->str.tab[i]);
    while (s != NULL) { str_bytes += lj_str_size(gco2str(s)->len); s = gcnext(s); }
  }
  fprintf(stderr, "GCCENSUS total_kb=%.1f str_num=%u str_mask=%u str_bytes=%llu "
	  "tab=%llu tab_asize=%llu tab_hnodes=%llu tab_bytes=%llu "
	  "func=%llu proto=%llu udata=%llu thread=%llu other=%llu\n",
	  (double)g->gc.total / 1024.0, (unsigned)g->str.num, (unsigned)g->str.mask,
	  (unsigned long long)str_bytes,
	  (unsigned long long)ntab, (unsigned long long)tab_asize,
	  (unsigned long long)tab_hnodes, (unsigned long long)tab_bytes,
	  (unsigned long long)nfunc, (unsigned long long)nproto,
	  (unsigned long long)nudata, (unsigned long long)nthr,
	  (unsigned long long)nother);
}

/* Called when a GC cycle completes: the cheap per-cycle line (or the full
** census under -DLUAJIT_GC_CENSUS).  Kept out of the macro below because a
** preprocessor conditional cannot appear inside a macro definition. */
static void gcstats_cycle_hook(global_State *g)
{
  /* Per-cycle phase split, so a cycle can be attributed to a workload stage.
  ** The timestamp is clock()/CLOCKS_PER_SEC, the same clock Lua's os.clock()
  ** reads, so a Lua stage probe can print matching stage boundaries. */
  static uint64_t last_mark, last_sweepstr, last_sweep, last_atomic;
  uint64_t m = gcstats.mark_ns - last_mark;
  uint64_t ss = gcstats.sweepstr_ns - last_sweepstr;
  uint64_t sw = gcstats.sweep_ns - last_sweep;
  uint64_t at = gcstats.atomic_ns - last_atomic;
  last_mark = gcstats.mark_ns; last_sweepstr = gcstats.sweepstr_ns;
  last_sweep = gcstats.sweep_ns; last_atomic = gcstats.atomic_ns;
#ifdef LUAJIT_GC_CENSUS
  gcstats_census(g);
#else
  fprintf(stderr, "GCCYC t=%.6f total_kb=%.1f str_num=%u str_mask=%u "
	  "cyc_mark_us=%.1f cyc_sweepstr_us=%.1f cyc_sweep_us=%.1f "
	  "cyc_atomic_us=%.1f cyc_total_us=%.1f\n",
	  (double)clock() / (double)CLOCKS_PER_SEC,
	  (double)g->gc.total / 1024.0, (unsigned)g->str.num, (unsigned)g->str.mask,
	  (double)m / 1000.0, (double)ss / 1000.0, (double)sw / 1000.0,
	  (double)at / 1000.0, (double)(m + ss + sw + at) / 1000.0);
#endif
}

#define GCSTATS_STEP_RET(v) do { \
  if ((v) == 1) gcstats_cycle_hook(g); \
  gcstats_pause(); \
  uint64_t _t = gcstats_now() - gcstats_t0; \
  gcstats.steps++; gcstats.step_ns += _t; \
  if (_t > gcstats.step_max_ns) gcstats.step_max_ns = _t; \
  gcstats_add(gcstats.step_hist, _t); \
  if ((v) == 1) gcstats.cycles++; \
  return (v); \
} while (0)
#else
#define GCSTATS_STEP_RET(v) return (v)
#define GCSTATS_ALLOC_OPEN()
#define GCSTATS_ALLOC_CLOSE() ((void)0)
#endif

#define GCSTEPSIZE	1024u
#define GCSWEEPMAX	40
#define GCSWEEPCOST	10
#define GCFINALIZECOST	100

static int gc_mayclear(cTValue *o, int val);

/* Stage-1 precursor: the string sweep is a pointer chase over the interned
** strings -- the optional stats build measures 60-91 ns per string visited,
** i.e. one cache miss each -- while the bucket array itself is walked in
** increasing index order.  The chain head of the bucket a few slots ahead is
** therefore a safe lookahead: prefetching it hides the miss without changing
** what the sweep does.  A hint only; no layout, no semantics.
**
** The hint is architecture-dependent and the default is set from measurement:
** it helps on x86_64 and costs on arm64, so it is off on every other target.
** -DLJ_STR_PREFETCH=N overrides (N=0 is the base build). */
#ifndef LJ_STR_PREFETCH
#if LJ_TARGET_X86ORX64
#define LJ_STR_PREFETCH	16
#else
#define LJ_STR_PREFETCH	0
#endif
#endif
#if LJ_STR_PREFETCH > 0 && (defined(__GNUC__) || defined(__clang__))
#define LJ_PREFETCH(p)	__builtin_prefetch(p)
#else
#define LJ_PREFETCH(p)	((void)0)
#endif

/* Macros to set GCobj colors and flags. */
#define white2gray(x)		((x)->gch.marked &= (uint8_t)~LJ_GC_WHITES)
#define gray2black(x)		((x)->gch.marked |= LJ_GC_BLACK)
#define isfinalized(u)		((u)->marked & LJ_GC_FINALIZED)

/* -- Mark phase ---------------------------------------------------------- */

/* Mark a TValue (if needed). */
#define gc_marktv(g, tv) \
  { lj_assertG(!tvisgcv(tv) || (~itype(tv) == gcval(tv)->gch.gct) || \
	       (LJ_FRAME_TAILMARK && itype(tv) == LJ_TTRACE && \
		gcval(tv)->gch.gct == ~LJ_TFUNC),  /* Tail-called frame. */ \
	       "TValue and GC type mismatch"); \
    if (tviswhite(tv)) gc_mark(g, gcV(tv)); }

/* Mark a GCobj (if needed). */
#define gc_markobj(g, o) \
  { if (iswhite(obj2gco(o))) gc_mark(g, obj2gco(o)); }

/* Mark a string object. */
#define gc_mark_str(s)		((s)->marked &= (uint8_t)~LJ_GC_WHITES)

/* Mark a white GCobj. */
static void gc_mark(global_State *g, GCobj *o)
{
  int gct = o->gch.gct;
  lj_assertG(iswhite(o), "mark of non-white object");
  lj_assertG(!isdead(g, o), "mark of dead object");
  white2gray(o);
  if (LJ_UNLIKELY(gct == ~LJ_TUDATA)) {
    GCtab *mt = tabref(gco2ud(o)->metatable);
    gray2black(o);  /* Userdata are never gray. */
    if (mt) gc_markobj(g, mt);
    gc_markobj(g, tabref(gco2ud(o)->env));
    if (gco2ud(o)->nuvalue) {  /* 5.4 user values. */
      TValue *uv = uduvs(gco2ud(o));
      MSize i;
      for (i = 0; i < gco2ud(o)->nuvalue; i++) gc_marktv(g, &uv[i]);
    }
    if (LJ_HASBUFFER && gco2ud(o)->udtype == UDTYPE_BUFFER) {
      SBufExt *sbx = (SBufExt *)uddata(gco2ud(o));
      if (sbufiscow(sbx) && gcref(sbx->cowref))
	gc_markobj(g, gcref(sbx->cowref));
      if (gcref(sbx->dict_str))
	gc_markobj(g, gcref(sbx->dict_str));
      if (gcref(sbx->dict_mt))
	gc_markobj(g, gcref(sbx->dict_mt));
    }
  } else if (LJ_UNLIKELY(gct == ~LJ_TUPVAL)) {
    GCupval *uv = gco2uv(o);
    gc_marktv(g, uvval(uv));
    if (uv->closed)
      gray2black(o);  /* Closed upvalues are never gray. */
  } else if (gct != ~LJ_TSTR && gct != ~LJ_TCDATA) {
    lj_assertG(gct == ~LJ_TFUNC || gct == ~LJ_TTAB ||
	       gct == ~LJ_TTHREAD || gct == ~LJ_TPROTO || gct == ~LJ_TTRACE,
	       "bad GC type %d", gct);
    setgcrefr(o->gch.gclist, g->gc.gray);
    setgcref(g->gc.gray, o);
  }
}

/* Mark GC roots. */
static void gc_mark_gcroot(global_State *g)
{
  ptrdiff_t i;
  for (i = 0; i < GCROOT_MAX; i++)
    if (gcref(g->gcroot[i]) != NULL)
      gc_markobj(g, gcref(g->gcroot[i]));
}

/* Start a GC cycle and mark the root set. */
static void gc_mark_start(global_State *g)
{
  setgcrefnull(g->gc.gray);
  setgcrefnull(g->gc.grayagain);
  setgcrefnull(g->gc.weak);
  gc_markobj(g, mainthread(g));
  gc_markobj(g, tabref(mainthread(g)->env));
  gc_markobj(g, vmthread(g));
  gc_marktv(g, &g->registrytv);
  gc_mark_gcroot(g);
  g->gc.state = GCSpropagate;
}

/* Mark open upvalues. */
static void gc_mark_uv(global_State *g)
{
  GCupval *uv;
  for (uv = uvnext(&g->uvhead); uv != &g->uvhead; uv = uvnext(uv)) {
    lj_assertG(uvprev(uvnext(uv)) == uv && uvnext(uvprev(uv)) == uv,
	       "broken upvalue chain");
    if (isgray(obj2gco(uv)))
      gc_marktv(g, uvval(uv));
  }
}

/* Mark userdata in mmudata list. */
static void gc_mark_mmudata(global_State *g)
{
  GCobj *root = gcref(g->gc.mmudata);
  GCobj *u = root;
  if (u) {
    do {
      u = gcnext(u);
      makewhite(g, u);  /* Could be from previous GC. */
      gc_mark(g, u);
    } while (u != root);
  }
}

/* Link an object to the end of the mmudata (to be finalized) list. */
static void gc_linkmmudata(global_State *g, GCobj *o)
{
  if (gcref(g->gc.mmudata)) {  /* Link to end of mmudata list. */
    GCobj *root = gcref(g->gc.mmudata);
    setgcrefr(o->gch.nextgc, root->gch.nextgc);
    setgcref(root->gch.nextgc, o);
    setgcref(g->gc.mmudata, o);
  } else {  /* Create circular list. */
    setgcref(o->gch.nextgc, o);
    setgcref(g->gc.mmudata, o);
  }
}

/* Separate userdata and tables to be finalized to mmudata list. */
size_t lj_gc_separateudata(global_State *g, int all)
{
  size_t m = 0;
  GCRef *p = &mainthread(g)->nextgc;
  GCobj *o;
  while ((o = gcref(*p)) != NULL) {
    /* Only userdata and candidate tables are linked after the main thread;
    ** the else branches below read the object as a userdata. */
    lj_assertG(o->gch.gct == ~LJ_TTAB || o->gch.gct == ~LJ_TUDATA,
	       "bad object type %d in the finalizer candidate list",
	       (int)~o->gch.gct);
    if (o->gch.gct == ~LJ_TTAB) {
      GCtab *t = gco2tab(o);
      /* A candidate table sits in the list after the main thread. Move it
      ** to the mmudata list (and mark it there) once it is unreachable. */
      if (!(iswhite(o) || all)) {
	p = &o->gch.nextgc;  /* Reachable: stays a candidate. */
      } else {
	m += sizeof(GCtab) + sizeof(TValue) * t->asize +
	     (t->hmask ? sizeof(Node) * (t->hmask + 1) : 0);
	t->marked |= LJ_GC_TABMM;  /* In mmudata (being finalized). */
	*p = o->gch.nextgc;
	gc_linkmmudata(g, o);
      }
    } else if (!(iswhite(o) || all) || isfinalized(gco2ud(o)) ||
	       g->gc.closing) {
      /* Nothing to do. 5.4 (GCSTPCLS): while lua_close runs, a userdata that
      ** gets __gc is registered nowhere, so it is freed without a finalizer. */
      p = &o->gch.nextgc;
    } else if (!lj_meta_fastg(g, tabref(gco2ud(o)->metatable), MM_gc)) {
      markfinalized(o);  /* Done, as there's no __gc metamethod. */
      p = &o->gch.nextgc;
    } else {  /* Otherwise move userdata to be finalized to mmudata list. */
      m += sizeudata(gco2ud(o));
      markfinalized(o);
      *p = o->gch.nextgc;
      gc_linkmmudata(g, o);
    }
  }
  return m;
}

/* Mark a table for finalization at setmetatable time (PUC luaC_checkfinalizer).
** A table that receives a metatable with a __gc field right now is moved to
** the finalizer candidate list (the list after the main thread). A later
** added __gc does not mark it; only this call does. LJ_GC_TABFIN marks the
** candidate (set here, cleared once finalized, like PUC's FINALIZEDBIT);
** LJ_GC_TABMM marks the table while it sits in the mmudata list. */
void lj_gc_checkfinalizer(lua_State *L, GCobj *o, GCtab *mt)
{
  global_State *g = G(L);
  GCobj *mth;
  GCtab *t;
  GCRef *p;
  if (o->gch.gct != ~LJ_TTAB || mt == NULL || g->gc.closing)
    return;
  t = gco2tab(o);
  if (t->marked & LJ_GC_TABFIN)
    return;  /* Already a candidate (no O(n) list walk). */
  if (!lj_meta_fastg(g, mt, MM_gc))
    return;
  /* Find the table in the main list (the region before the main thread).
  ** A table that is not yet a candidate always lives there. */
  mth = obj2gco(mainthread(g));
  for (p = &g->gc.root; gcref(*p) != NULL && gcref(*p) != mth;
       p = &gcref(*p)->gch.nextgc) {
    if (gcref(*p) == o)
      break;
  }
  if (gcref(*p) != o)
    return;
  if (g->gc.state == GCSsweepstring || g->gc.state == GCSsweep)
    makewhite(g, o);  /* Keep it alive for the rest of the current sweep. */
  t->marked |= LJ_GC_TABFIN;
  *p = o->gch.nextgc;
  /* If the sweep cursor rests on the moved object's link, move it to the
  ** link that now points at the object's successor. Otherwise the sweep
  ** would follow the object into the candidate list and skip every object
  ** between its old position and the main thread. */
  if (mref(g->gc.sweep, GCRef) == &o->gch.nextgc)
    setmref(g->gc.sweep, p);
  /* Prepend it to the candidate list after the main thread. */
  setgcrefr(o->gch.nextgc, mainthread(g)->nextgc);
  setgcref(mainthread(g)->nextgc, o);
}

/* -- Propagation phase --------------------------------------------------- */

/* Traverse a table. */
static int gc_traverse_tab(global_State *g, GCtab *t)
{
  int weak = 0;
  cTValue *mode;
  GCtab *mt = tabref(t->metatable);
  if (mt)
    gc_markobj(g, mt);
  mode = lj_meta_fastg(g, mt, MM_mode);
  if (mode && tvisstr(mode)) {  /* Valid __mode field? */
    const char *modestr = strVdata(mode);
    int c;
    while ((c = *modestr++)) {
      if (c == 'k') weak |= LJ_GC_WEAKKEY;
      else if (c == 'v') weak |= LJ_GC_WEAKVAL;
    }
    if (weak) {  /* Weak tables are cleared in the atomic phase. */
#if LJ_HASFFI
      if (gcref(g->gcroot[GCROOT_FFI_FIN]) == obj2gco(t)) {
	weak = (int)(~0u & ~LJ_GC_WEAKVAL);
      } else
#endif
      {
	t->marked = (uint8_t)((t->marked & ~LJ_GC_WEAK) | weak);
	setgcrefr(t->gclist, g->gc.weak);
	setgcref(g->gc.weak, obj2gco(t));
      }
    }
  }
  /* ADR-001b: a boxed 5.4 integer is a value, not an object a weak table
  ** may drop -- it is always marked, whichever part is weak. */
  if (weak == LJ_GC_WEAK) {  /* Only boxed integers to mark if both are weak. */
    MSize i, asize = t->asize;
    for (i = 0; i < asize; i++)
      if (tvisi64(arrayslot(t, i))) gc_marktv(g, arrayslot(t, i));
  } else if (!(weak & LJ_GC_WEAKVAL)) {  /* Mark array part. */
    MSize i, asize = t->asize;
    for (i = 0; i < asize; i++)
      gc_marktv(g, arrayslot(t, i));
  } else {
    MSize i, asize = t->asize;
    for (i = 0; i < asize; i++)
      if (tvisi64(arrayslot(t, i))) gc_marktv(g, arrayslot(t, i));
  }
  if (t->hmask > 0) {  /* Mark hash part. */
    Node *node = noderef(t->node);
    MSize i, hmask = t->hmask;
    for (i = 0; i <= hmask; i++) {
      Node *n = &node[i];
      if (!tvisnil(&n->val)) {  /* Mark non-empty slot. */
	lj_assertG(!tvisnil(&n->key), "mark of nil key in non-empty slot");
	if (weak == LJ_GC_WEAKKEY) {
	  /* Ephemeron: the value is marked only when the key is (or never can
	  ** be) cleared; a string key is marked by gc_mayclear and counts as
	  ** marked, a boxed 5.4 integer key is marked here. */
	  if (tvisi64(&n->key)) gc_marktv(g, &n->key);
	  if (!gc_mayclear(&n->key, 0) && tvisgcv(&n->val) &&
	      iswhite(gcV(&n->val)))
	    gc_marktv(g, &n->val);
	} else {
	  if (!(weak & LJ_GC_WEAKKEY) || tvisi64(&n->key)) gc_marktv(g, &n->key);
	  if (!(weak & LJ_GC_WEAKVAL) || tvisi64(&n->val)) gc_marktv(g, &n->val);
	}
      }
    }
  }
  return weak;
}

/* Traverse a function. */
static void gc_traverse_func(global_State *g, GCfunc *fn)
{
  gc_marktv(g, &fn->c.envv);  /* The 5.4 _ENV value (any type). */
  if (gcref(fn->c.env) != NULL)  /* Table cache, NULL for a non-table env. */
    gc_markobj(g, tabref(fn->c.env));
  if (isluafunc(fn)) {
    uint32_t i;
    lj_assertG(fn->l.nupvalues <= funcproto(fn)->sizeuv,
	       "function upvalues out of range");
    gc_markobj(g, funcproto(fn));
    for (i = 0; i < fn->l.nupvalues; i++)  /* Mark Lua function upvalues. */
      gc_markobj(g, &gcref(fn->l.uvptr[i])->uv);
  } else {
    uint32_t i;
    for (i = 0; i < fn->c.nupvalues; i++)  /* Mark C function upvalues. */
      gc_marktv(g, &fn->c.upvalue[i]);
  }
}

#if LJ_HASJIT
/* Mark a trace. */
static void gc_marktrace(global_State *g, TraceNo traceno)
{
  GCobj *o = obj2gco(traceref(G2J(g), traceno));
  lj_assertG(traceno != G2J(g)->cur.traceno, "active trace escaped");
  if (iswhite(o)) {
    white2gray(o);
    setgcrefr(o->gch.gclist, g->gc.gray);
    setgcref(g->gc.gray, o);
  }
}

/* Traverse a trace. */
static void gc_traverse_trace(global_State *g, GCtrace *T)
{
  IRRef ref;
  if (T->traceno == 0) return;
  for (ref = T->nk; ref < REF_TRUE; ref++) {
    IRIns *ir = &T->ir[ref];
    if (ir->o == IR_KGC)
      gc_markobj(g, ir_kgc(ir));
    if (irt_is64(ir->t) && ir->o != IR_KNULL)
      ref++;
  }
  if (T->link) gc_marktrace(g, T->link);
  if (T->nextroot) gc_marktrace(g, T->nextroot);
  if (T->nextside) gc_marktrace(g, T->nextside);
  gc_markobj(g, gcref(T->startpt));
}

/* The current trace is a GC root while not anchored in the prototype (yet). */
#define gc_traverse_curtrace(g)	gc_traverse_trace(g, &G2J(g)->cur)
#else
#define gc_traverse_curtrace(g)	UNUSED(g)
#endif

/* Traverse a prototype. */
static void gc_traverse_proto(global_State *g, GCproto *pt)
{
  ptrdiff_t i;
  gc_mark_str(proto_chunkname(pt));
  for (i = -(ptrdiff_t)pt->sizekgc; i < 0; i++)  /* Mark collectable consts. */
    gc_markobj(g, proto_kgc(pt, i));
#if LJ_HASJIT
  if (pt->trace) gc_marktrace(g, pt->trace);
#endif
}

/* Traverse the frame structure of a stack. */
static MSize gc_traverse_frames(global_State *g, lua_State *th)
{
  TValue *frame, *top = th->top-1, *bot = tvref(th->stack);
  /* Note: extra vararg frame not skipped, marks function twice (harmless). */
  for (frame = th->base-1; frame > bot+LJ_FR2; frame = frame_prev(frame)) {
    GCfunc *fn = frame_func(frame);
    TValue *ftop = frame;
    if (isluafunc(fn)) ftop += funcproto(fn)->framesize;
    if (ftop > top) top = ftop;
    if (!LJ_FR2) gc_markobj(g, fn);  /* Need to mark hidden function (or L). */
  }
  top++;  /* Correct bias of -1 (frame == base-1). */
  if (top > tvref(th->maxstack)) top = tvref(th->maxstack);
  return (MSize)(top - bot);  /* Return minimum needed stack size. */
}

/* Traverse a thread object. */
static void gc_traverse_thread(global_State *g, lua_State *th)
{
  TValue *o, *top = th->top;
  for (o = tvref(th->stack)+1+LJ_FR2; o < top; o++)
    gc_marktv(g, o);
  if (g->gc.state == GCSatomic) {
    top = tvref(th->stack) + th->stacksize;
    for (; o < top; o++)  /* Clear unmarked slots. */
      setnilV(o);
  }
  gc_markobj(g, tabref(th->env));
  lj_state_shrinkstack(th, gc_traverse_frames(g, th));
}

/* Propagate one gray object. Traverse it and turn it black. */
static size_t propagatemark(global_State *g)
{
  GCobj *o = gcref(g->gc.gray);
  int gct = o->gch.gct;
  lj_assertG(isgray(o), "propagation of non-gray object");
  gray2black(o);
  setgcrefr(g->gc.gray, o->gch.gclist);  /* Remove from gray list. */
  if (LJ_LIKELY(gct == ~LJ_TTAB)) {
    GCtab *t = gco2tab(o);
    if (gc_traverse_tab(g, t) > 0)
      black2gray(o);  /* Keep weak tables gray. */
    return sizeof(GCtab) + sizeof(TValue) * t->asize +
			   (t->hmask ? sizeof(Node) * (t->hmask + 1) : 0);
  } else if (LJ_LIKELY(gct == ~LJ_TFUNC)) {
    GCfunc *fn = gco2func(o);
    gc_traverse_func(g, fn);
    return isluafunc(fn) ? sizeLfunc((MSize)fn->l.nupvalues) :
			   sizeCfunc((MSize)fn->c.nupvalues);
  } else if (LJ_LIKELY(gct == ~LJ_TPROTO)) {
    GCproto *pt = gco2pt(o);
    gc_traverse_proto(g, pt);
    return pt->sizept;
  } else if (LJ_LIKELY(gct == ~LJ_TTHREAD)) {
    lua_State *th = gco2th(o);
    setgcrefr(th->gclist, g->gc.grayagain);
    setgcref(g->gc.grayagain, o);
    black2gray(o);  /* Threads are never black. */
    gc_traverse_thread(g, th);
    return sizeof(lua_State) + sizeof(TValue) * th->stacksize;
  } else {
#if LJ_HASJIT
    GCtrace *T = gco2trace(o);
    gc_traverse_trace(g, T);
    return ((sizeof(GCtrace)+7)&~7) + (T->nins-T->nk)*sizeof(IRIns) +
	   T->nsnap*sizeof(SnapShot) + T->nsnapmap*sizeof(SnapEntry);
#else
    lj_assertG(0, "bad GC type %d", gct);
    return 0;
#endif
  }
}

/* Propagate all gray objects. */
static size_t gc_propagate_gray(global_State *g)
{
  size_t m = 0;
  while (gcref(g->gc.gray) != NULL)
    m += propagatemark(g);
  return m;
}

/* -- Sweep phase --------------------------------------------------------- */

/* Type of GC free functions. */
typedef void (LJ_FASTCALL *GCFreeFunc)(global_State *g, GCobj *o);

/* GC free functions for LJ_TSTR .. LJ_TUDATA. ORDER LJ_T */
static const GCFreeFunc gc_freefunc[] = {
  (GCFreeFunc)lj_str_free,
  (GCFreeFunc)lj_func_freeuv,
  (GCFreeFunc)lj_state_free,
  (GCFreeFunc)lj_func_freeproto,
  (GCFreeFunc)lj_func_free,
#if LJ_HASJIT
  (GCFreeFunc)lj_trace_free,
#else
  (GCFreeFunc)0,
#endif
#if LJ_HASFFI
  (GCFreeFunc)lj_cdata_free,
#else
  (GCFreeFunc)0,
#endif
  (GCFreeFunc)lj_tab_free,
  (GCFreeFunc)lj_udata_free
};

/* Full sweep of a GC list. */
#define gc_fullsweep(g, p)	gc_sweep(g, (p), ~(uint32_t)0)

/* Partial sweep of a GC list. */
static GCRef *gc_sweep(global_State *g, GCRef *p, uint32_t lim)
{
  /* Mask with other white and LJ_GC_FIXED. Or LJ_GC_SFIXED on shutdown. */
  int ow = otherwhite(g);
  GCobj *o;
  while ((o = gcref(*p)) != NULL && lim-- > 0) {
    if (o->gch.gct == ~LJ_TTHREAD)  /* Need to sweep open upvalues, too. */
      gc_fullsweep(g, &gco2th(o)->openupval);
    if (((o->gch.marked ^ LJ_GC_WHITES) & ow)) {  /* Black or current white? */
      lj_assertG(!isdead(g, o) || (o->gch.marked & LJ_GC_FIXED),
		 "sweep of undead object");
      makewhite(g, o);  /* Value is alive, change to the current white. */
      p = &o->gch.nextgc;
    } else {  /* Otherwise value is dead, free it. */
      lj_assertG(isdead(g, o) || ow == LJ_GC_SFIXED,
		 "sweep of unlive object");
      setgcrefr(*p, o->gch.nextgc);
      if (o == gcref(g->gc.root))
	setgcrefr(g->gc.root, o->gch.nextgc);  /* Adjust list anchor. */
      /* ADR-001b: a dead boxed int64 must leave the intern hash first. */
      if (LJ_LIKELY(o->gch.gct == ~LJ_TUDATA) &&
	  gco2ud(o)->udtype == UDTYPE_I64BOX)
	lj_i64_remove(g, gco2ud(o));
      gc_freefunc[o->gch.gct - ~LJ_TSTR](g, o);
    }
  }
  return p;
}

/* Sweep one string interning table chain. Preserves hashalg bit. */
static void gc_sweepstr(global_State *g, GCRef *chain)
{
  /* Mask with other white and LJ_GC_FIXED. Or LJ_GC_SFIXED on shutdown. */
  int ow = otherwhite(g);
  uintptr_t u = gcrefu(*chain);
  GCRef q;
  GCRef *p = &q;
  GCobj *o;
  setgcrefp(q, (u & ~(uintptr_t)1));
  while ((o = gcref(*p)) != NULL) {
    if (((o->gch.marked ^ LJ_GC_WHITES) & ow)) {  /* Black or current white? */
      lj_assertG(!isdead(g, o) || (o->gch.marked & LJ_GC_FIXED),
		 "sweep of undead string");
      makewhite(g, o);  /* String is alive, change to the current white. */
      p = &o->gch.nextgc;
    } else {  /* Otherwise string is dead, free it. */
      lj_assertG(isdead(g, o) || ow == LJ_GC_SFIXED,
		 "sweep of unlive string");
      setgcrefr(*p, o->gch.nextgc);
      lj_str_free(g, gco2str(o));
    }
  }
  setgcrefp(*chain, (gcrefu(q) | (u & 1)));
}

/* Check whether we can clear a key or a value slot from a table. */
static int gc_mayclear(cTValue *o, int val)
{
  if (tvisgcv(o)) {  /* Only collectable objects can be weak references. */
    if (tvisstr(o)) {  /* But strings cannot be used as weak references. */
      gc_mark_str(strV(o));  /* And need to be marked. */
      return 0;
    }
    if (tvisi64(o))
      return 0;  /* A boxed 5.4 integer is a value (and was marked). */
    if (iswhite(gcV(o)))
      return 1;  /* Object is about to be collected. */
    if (tvisudata(o) && val && isfinalized(udataV(o)))
      return 1;  /* Finalized userdata is dropped only from values. */
    if (tvistab(o) && val && (tabV(o)->marked & LJ_GC_TABMM))
      return 1;  /* A table being finalized is dropped from values. */
  }
  return 0;  /* Cannot clear. */
}

/* Clear collected values from weak tables, as PUC's clearbyvalues. Only
** tables with a weak value part are touched; keys are a separate pass. If
** stop is not NULL, stop when that table is reached (PUC's origweak/origall
** prefix: only tables re-linked after the resurrection marks are cleared). */
static void gc_clearweak_vals(global_State *g, GCobj *o, GCobj *stop)
{
  UNUSED(g);
  while (o != NULL && o != stop) {
    GCtab *t = gco2tab(o);
    lj_assertG((t->marked & LJ_GC_WEAK), "clear of non-weak table");
    if ((t->marked & LJ_GC_WEAKVAL)) {
      MSize i, asize = t->asize;
      for (i = 0; i < asize; i++) {
	/* Clear array slot when value is about to be collected. */
	TValue *tv = arrayslot(t, i);
	if (gc_mayclear(tv, 1))
	  setnilV(tv);
      }
      if (t->hmask > 0) {
	Node *node = noderef(t->node);
	MSize i, hmask = t->hmask;
	for (i = 0; i <= hmask; i++) {
	  Node *n = &node[i];
	  /* Clear hash value; its key is left to the key pass. */
	  if (!tvisnil(&n->val) && gc_mayclear(&n->val, 1))
	    setnilV(&n->val);
	}
      }
    }
    o = gcref(t->gclist);
  }
}

/* Clear entries of weak-key tables whose key is about to be collected
** (PUC's clearbykeys, after the resurrection marks). */
static void gc_clearweak_keys(global_State *g, GCobj *o)
{
  UNUSED(g);
  while (o != NULL) {
    GCtab *t = gco2tab(o);
    lj_assertG((t->marked & LJ_GC_WEAK), "clear of non-weak table");
    if ((t->marked & LJ_GC_WEAKKEY) && t->hmask > 0) {
      Node *node = noderef(t->node);
      MSize i, hmask = t->hmask;
      for (i = 0; i <= hmask; i++) {
	Node *n = &node[i];
	if (!tvisnil(&n->val) && gc_mayclear(&n->key, 0))
	  setnilV(&n->val);
      }
    }
    o = gcref(t->gclist);
  }
}

/* One ephemeron convergence pass: mark a weak-key table's value when its key
** is already marked (or can never be cleared: a string key is marked by
** gc_mayclear, numbers/booleans are not collectable, the boxed integer key
** is marked). Ephemeron tables are WEAKKEY without WEAKVAL. */
static int gc_ephemeron_pass(global_State *g)
{
  GCobj *o = gcref(g->gc.weak);
  int marked = 0;
  while (o != NULL) {
    GCtab *t = gco2tab(o);
    if ((t->marked & LJ_GC_WEAKKEY) && !(t->marked & LJ_GC_WEAKVAL) &&
	t->hmask > 0) {
      Node *node = noderef(t->node);
      MSize i, hmask = t->hmask;
      for (i = 0; i <= hmask; i++) {
	Node *n = &node[i];
	if (!tvisnil(&n->val) && tvisgcv(&n->val) &&
	    iswhite(gcV(&n->val)) && !gc_mayclear(&n->key, 0)) {
	  gc_marktv(g, &n->val);
	  marked = 1;
	}
      }
    }
    o = gcref(t->gclist);
  }
  return marked;
}

/* PUC lgc.c convergeephemerons: repeat until no new mark. The direction
** inversion PUC uses is only a speed-up; correctness needs the fixpoint. */
static void gc_converge_ephemerons(global_State *g)
{
  while (gc_ephemeron_pass(g))
    gc_propagate_gray(g);
}

/* Call a userdata or cdata finalizer. */
static void gc_call_finalizer(global_State *g, lua_State *L,
			      cTValue *mo, GCobj *o)
{
  /* Save and restore lots of state around the __gc callback. */
  uint8_t oldh = hook_save(g);
  GCSize oldt = g->gc.threshold;
  uint8_t oldfinizing = g->gc.finalizing;
  int errcode;
  lua_State *VL = vmthread(g);
  MSize oldfin = g->finbase;
  MSize oldnest = VL->ccallnest, oldnbase = VL->ccallbase;
  TValue *top;
  lj_trace_abort(g);
  hook_entergc(g);  /* Disable hooks and new traces during __gc. */
  if (LJ_HASPROFILE && (oldh & HOOK_PROFILE)) lj_dispatch_update(g, 0);
  g->gc.threshold = LJ_MAX_MEM;  /* Prevent GC steps. */
  g->gc.finalizing = 1;  /* 5.4 GCSTPGC: lua_gc() fails in every __gc */
  top = VL->top;
  copyTV(VL, top++, mo);
  if (LJ_FR2) setnilV(top++);
  setgcV(VL, top, o, ~o->gch.gct);
  VL->top = top+1;
  /* 5.4 debug.getinfo names this frame "metamethod '__gc'". */
  g->finbase = (MSize)((top-1) - tvref(VL->stack));
  /* 5.4: the finalizer is one C call deeper than the code the collector
  ** interrupted (PUC GCTM). The finalizer thread takes over that count. */
  VL->ccallnest = VL->ccallbase = L->ccallnest;
  if (lj_err_ccallover(VL)) {  /* PUC: the error of the protected call. */
    setstrV(VL, top-1-LJ_FR2, lj_err_str(VL,
      VL->ccallnest >= LJ_MAX_CCALLSERR ? LJ_ERR_ERRERR : LJ_ERR_CSTKOV));
    VL->top = top-LJ_FR2;
    errcode = LUA_ERRRUN;
  } else {
    VL->ccallnest++;
    errcode = lj_vm_pcall(VL, top, 1+0, -1);  /* Stack: |mo|o| -> | */
  }
  VL->ccallnest = oldnest;
  VL->ccallbase = oldnbase;
  g->finbase = oldfin;
  g->gc.finalizing = oldfinizing;
  setgcref(g->cur_L, obj2gco(L));
  hook_restore(g, oldh);
  if (LJ_HASPROFILE && (oldh & HOOK_PROFILE)) lj_dispatch_update(g, 0);
  g->gc.threshold = oldt;  /* Restore GC threshold. */
  if (errcode) {
    TValue tmp;
    copyTV(VL, &tmp, VL->top-1);
    VL->top--;
    lj_vmevent_send(g, ERRFIN,
      copyTV(V, V->top++, &tmp);
    );
  }
}

/* Finalize one userdata or cdata object from the mmudata list. */
static void gc_finalize(lua_State *L)
{
  global_State *g = G(L);
  GCobj *o = gcnext(gcref(g->gc.mmudata));
  cTValue *mo;
  lj_assertG(tvref(g->jit_base) == NULL, "finalizer called on trace");
  /* Unchain from list of userdata to be finalized. */
  if (o == gcref(g->gc.mmudata))
    setgcrefnull(g->gc.mmudata);
  else
    setgcrefr(gcref(g->gc.mmudata)->gch.nextgc, o->gch.nextgc);
#if LJ_HASFFI
  if (o->gch.gct == ~LJ_TCDATA) {
    TValue tmp, *tv;
    /* Add cdata back to the GC list and make it white. */
    setgcrefr(o->gch.nextgc, g->gc.root);
    setgcref(g->gc.root, o);
    makewhite(g, o);
    o->gch.marked &= (uint8_t)~LJ_GC_CDATA_FIN;
    /* Resolve finalizer. */
    setcdataV(L, &tmp, gco2cd(o));
    tv = lj_tab_set(L, tabref(g->gcroot[GCROOT_FFI_FIN]), &tmp);
    if (!tvisnil(tv)) {
      copyTV(L, &tmp, tv);
      setnilV(tv);  /* Clear entry in finalizer table. */
      gc_call_finalizer(g, L, &tmp, o);
    }
    return;
  }
#endif
  if (o->gch.gct == ~LJ_TTAB) {
    GCtab *t = gco2tab(o);
    /* Add the table back to the main GC list and make it white. Clearing
    ** LJ_GC_TABFIN/TABMM is the "already finalized" state; the table is
    ** finalized again only after a new setmetatable with __gc (PUC resets
    ** the bit). */
    setgcrefr(o->gch.nextgc, g->gc.root);
    setgcref(g->gc.root, o);
    makewhite(g, o);
    o->gch.marked &= (uint8_t)~(LJ_GC_TABFIN | LJ_GC_TABMM);
    mo = lj_meta_fastg(g, tabref(t->metatable), MM_gc);
    if (mo)
      gc_call_finalizer(g, L, mo, o);
    return;
  }
  /* Add userdata back to the main userdata list and make it white. */
  setgcrefr(o->gch.nextgc, mainthread(g)->nextgc);
  setgcref(mainthread(g)->nextgc, o);
  makewhite(g, o);
  /* Resolve the __gc metamethod. */
  mo = lj_meta_fastg(g, tabref(gco2ud(o)->metatable), MM_gc);
  if (mo)
    gc_call_finalizer(g, L, mo, o);
}

/* Finalize all userdata objects from mmudata list. */
void lj_gc_finalize_udata(lua_State *L)
{
  while (gcref(G(L)->gc.mmudata) != NULL)
    gc_finalize(L);
}

#if LJ_HASFFI
/* Finalize all cdata objects from finalizer table. */
void lj_gc_finalize_cdata(lua_State *L)
{
  global_State *g = G(L);
  GCtab *t = tabref(g->gcroot[GCROOT_FFI_FIN]);
  Node *node = noderef(t->node);
  ptrdiff_t i;
  setgcrefnull(t->metatable);  /* Mark finalizer table as disabled. */
  for (i = (ptrdiff_t)t->hmask; i >= 0; i--)
    if (!tvisnil(&node[i].val) && tviscdata(&node[i].key)) {
      GCobj *o = gcV(&node[i].key);
      TValue tmp;
      makewhite(g, o);
      o->gch.marked &= (uint8_t)~LJ_GC_CDATA_FIN;
      copyTV(L, &tmp, &node[i].val);
      setnilV(&node[i].val);
      gc_call_finalizer(g, L, &tmp, o);
    }
}
#endif

/* Free all remaining GC objects. */
void lj_gc_freeall(global_State *g)
{
  MSize i;
  /* Free everything, except super-fixed objects (the main thread). */
  g->gc.currentwhite = LJ_GC_WHITES | LJ_GC_SFIXED;
  gc_fullsweep(g, &g->gc.root);
  for (i = g->str.mask; i != ~(MSize)0; i--)  /* Free all string hash chains. */
    gc_sweepstr(g, &g->str.tab[i]);
}

/* -- Collector ----------------------------------------------------------- */

/* Atomic part of the GC cycle, transitioning from mark to sweep phase. */
static void atomic(global_State *g, lua_State *L)
{
  size_t udsize;
  GCobj *origweak;

  gc_mark_uv(g);  /* Need to remark open upvalues (the thread may be dead). */
  gc_propagate_gray(g);  /* Propagate any left-overs. */

  setgcrefr(g->gc.gray, g->gc.weak);  /* Empty the list of weak tables. */
  setgcrefnull(g->gc.weak);
  lj_assertG(!iswhite(obj2gco(mainthread(g))), "main thread turned white");
  gc_markobj(g, L);  /* Mark running thread. */
#if LJ_HASFFI
  if (ctype_ctsG(g) && ctype_ctsG(g)->L)  /* Mark cts->L thread. */
    gc_markobj(g, ctype_ctsG(g)->L);
#endif
  gc_traverse_curtrace(g);  /* Traverse current trace. */
  gc_mark_gcroot(g);  /* Mark GC roots (again). */
  gc_propagate_gray(g);  /* Propagate all of the above. */

  setgcrefr(g->gc.gray, g->gc.grayagain);  /* Empty the 2nd chance list. */
  setgcrefnull(g->gc.grayagain);
  gc_propagate_gray(g);  /* Propagate it. */

  gc_converge_ephemerons(g);  /* PUC: converge before clearing weak values. */

  /* PUC lgc.c atomic: clear weak values before checking finalizers, so the
  ** finalizer of a weakly referenced object sees the entry gone. The saved
  ** head is PUC's origweak: only tables re-linked by the resurrection marks
  ** are cleared again below. */
  gc_clearweak_vals(g, gcref(g->gc.weak), NULL);
  origweak = gcref(g->gc.weak);

  udsize = lj_gc_separateudata(g, 0);  /* Separate userdata to be finalized. */
  gc_mark_mmudata(g);  /* Mark them. */
  udsize += gc_propagate_gray(g);  /* And propagate the marks. */
  gc_converge_ephemerons(g);  /* PUC: converge again after resurrection marks. */

  /* All marking done: clear dead ephemeron/allweak keys, then the values of
  ** the weak tables that resurrection linked again (PUC clearbykeys, then
  ** clearbyvalues(weak, origweak)). */
  gc_clearweak_keys(g, gcref(g->gc.weak));
  gc_clearweak_vals(g, gcref(g->gc.weak), origweak);

  { /* PUC has no global temp buffer. Releasing it returns collectgarbage("count")
  ** to the pre-fill baseline after a weak kv table is cleared; halving it left
  ** the buffer resident for several cycles (gc.lua:487). A buffer built by a
  ** string/tostring/format call is only alive inside that call -- the owning
  ** C function copies the content out before its trailing lj_gc_check -- and
  ** finalizers run after atomic, so it can be freed here. */
    SBuf *sb = &g->tmpbuf;
    MSize sz = sbufsz(sb);
    if (sz > LJ_MIN_SBUF) {
      lj_mem_free(g, sb->b, sz);
      sb->w = sb->b = sb->e = NULL;
    }
  }

  /* Prepare for sweep phase. */
  g->gc.currentwhite = (uint8_t)otherwhite(g);  /* Flip current white. */
  g->strempty.marked = g->gc.currentwhite;
  setmref(g->gc.sweep, &g->gc.root);
  g->gc.estimate = g->gc.total - (GCSize)udsize;  /* Initial estimate. */
}

/* GC state machine. Returns a cost estimate for each step performed. */
static size_t gc_onestep(lua_State *L)
{
  global_State *g = G(L);
  size_t r;
#ifdef LUAJIT_GC_STATS
  /* Open a phase run if the collector was paused, or close and reopen it when
  ** the state changed.  Two clock reads per state change, none per step. */
  if (!gcstats_run)
    gcstats_resume(g);
  else if ((uint8_t)g->gc.state != gcstats_phase_state)
    gcstats_switch(g);
  gcstats_step_count((int)g->gc.state);
#endif
  switch (g->gc.state) {
  case GCSpause:
    gc_mark_start(g);  /* Start a new GC cycle by marking all GC roots. */
    r = 0;
    break;
  case GCSpropagate:
    if (gcref(g->gc.gray) != NULL)
      r = propagatemark(g);  /* Propagate one gray object. */
    else {
      g->gc.state = GCSatomic;  /* End of mark phase. */
      r = 0;
    }
    break;
  case GCSatomic:
    if (tvref(g->jit_base)) {  /* Don't run atomic phase on trace. */
      r = LJ_MAX_MEM;
      break;
    }
#ifdef LUAJIT_GC_STATS
    {
      uint64_t t0 = gcstats_now();
      atomic(g, L);
      uint64_t dt = gcstats_now() - t0;
      gcstats.atomic_calls++; gcstats.atomic_ns += dt;
      if (dt > gcstats.atomic_max_ns) gcstats.atomic_max_ns = dt;
      gcstats_add(gcstats.atomic_hist, dt);
    }
#else
    atomic(g, L);
#endif
    g->gc.state = GCSsweepstring;  /* Start of sweep phase. */
    g->gc.sweepstr = 0;
    r = 0;
    break;
  case GCSsweepstring: {
    GCSize old = g->gc.total;
    gc_sweepstr(g, &g->str.tab[g->gc.sweepstr++]);  /* Sweep one chain. */
#if LJ_STR_PREFETCH > 0
    if (g->gc.sweepstr + LJ_STR_PREFETCH <= g->str.mask)
      LJ_PREFETCH(gcref(g->str.tab[g->gc.sweepstr + LJ_STR_PREFETCH]));
#endif
    if (g->gc.sweepstr > g->str.mask)
      g->gc.state = GCSsweep;  /* All string hash chains sweeped. */
    lj_assertG(old >= g->gc.total, "sweep increased memory");
    g->gc.estimate -= old - g->gc.total;
    r = GCSWEEPCOST;
    break;
    }
  case GCSsweep: {
    GCSize old = g->gc.total;
    setmref(g->gc.sweep, gc_sweep(g, mref(g->gc.sweep, GCRef), GCSWEEPMAX));
    lj_assertG(old >= g->gc.total, "sweep increased memory");
    g->gc.estimate -= old - g->gc.total;
    if (gcref(*mref(g->gc.sweep, GCRef)) == NULL) {
      if (g->str.num <= (g->str.mask >> 2) && g->str.mask > LJ_MIN_STRTAB*2-1)
	lj_str_resize(L, g->str.mask >> 1);  /* Shrink string table. */
      if (gcref(g->gc.mmudata)) {  /* Need any finalizations? */
	g->gc.state = GCSfinalize;
      } else {  /* Otherwise skip this phase to help the JIT. */
	g->gc.state = GCSpause;  /* End of GC cycle. */
	g->gc.debt = 0;
      }
    }
    r = GCSWEEPMAX*GCSWEEPCOST;
    break;
    }
  case GCSfinalize:
    if (gcref(g->gc.mmudata) != NULL) {
      GCSize old = g->gc.total;
      if (tvref(g->jit_base)) {  /* Don't call finalizers on trace. */
	r = LJ_MAX_MEM;
	break;
      }
      gc_finalize(L);  /* Finalize one userdata object. */
      if (old >= g->gc.total && g->gc.estimate > old - g->gc.total)
	g->gc.estimate -= old - g->gc.total;
      if (g->gc.estimate > GCFINALIZECOST)
	g->gc.estimate -= GCFINALIZECOST;
      r = GCFINALIZECOST;
      break;
    }
    g->gc.state = GCSpause;  /* End of GC cycle. */
    g->gc.debt = 0;
    r = 0;
    break;
  default:
    lj_assertG(0, "bad GC state");
    r = 0;
    break;
  }
  return r;
}

/* Perform a limited amount of incremental GC steps. */
int LJ_FASTCALL lj_gc_step(lua_State *L)
{
  global_State *g = G(L);
  GCSize lim;
  int32_t ostate = g->vmstate;
#ifdef LUAJIT_GC_STATS
  uint64_t gcstats_t0 = gcstats_now();
#endif
  setvmstate(g, GC);
  lim = (GCSTEPSIZE/100) * (g->gc.stepmul * 4);
  if (lim == 0)
    lim = GCSTEPSIZE/100;  /* PUC incstep: stepmul 0 still does one step */
  if (g->gc.total > g->gc.threshold)
    g->gc.debt += g->gc.total - g->gc.threshold;
  do {
    lim -= (GCSize)gc_onestep(L);
    if (g->gc.state == GCSpause) {
      g->gc.threshold = (g->gc.estimate/100) * (g->gc.pause * 4);
      g->vmstate = ostate;
      GCSTATS_STEP_RET(1);  /* Finished a GC cycle. */
    }
  } while (sizeof(lim) == 8 ? ((int64_t)lim > 0) : ((int32_t)lim > 0));
  if (g->gc.debt < GCSTEPSIZE) {
    g->gc.threshold = g->gc.total + GCSTEPSIZE;
    g->vmstate = ostate;
    GCSTATS_STEP_RET(-1);
  } else {
    g->gc.debt -= GCSTEPSIZE;
    g->gc.threshold = g->gc.total;
    g->vmstate = ostate;
    GCSTATS_STEP_RET(0);
  }
}

/* Ditto, but fix the stack top first. */
void LJ_FASTCALL lj_gc_step_fixtop(lua_State *L)
{
  if (curr_funcisL(L)) L->top = curr_topL(L);
  lj_gc_step(L);
}

/* Ditto, with the live top passed by the VM (PUC's checkGC(L,c)). */
void lj_gc_step_top(lua_State *L, TValue *top)
{
  L->top = top;
  lj_gc_step(L);
}

#if LJ_HASJIT
/* Perform multiple GC steps. Called from JIT-compiled code. */
#if LJ_TARGET_ARM64 || (LJ_TARGET_X86ORX64 && LJ_GC64)
/* GC64 targets pass a 64-bit pak: traceno(16), loop-head flag(16), steps(32). */

/* Stale values left in the stack slots above the live range are roots while
** the interpreter has not overwritten them, and a trace never writes them
** (a store to a dead local is not recorded at all): a compiled loop that
** waits for such a value to be collected would wait forever. This is called
** for a GC check at the start bytecode of the trace. Slots that are read by
** any bytecode from the start pc onward (including loop control slots) keep
** their value; every other slot is dead at the start pc and is cleared, as
** PUC's checkGC narrows the top and the atomic phase nils the dead slice.
** Slots an open upvalue points to are kept, as the snapshot use/def analysis
** does.
*/
/* Mark slots read by bytecode in [from,to) and, when wr is not NULL, slots
** it writes. Opcode modes follow the snapshot analysis in lj_snap.c. */
static void gc_jit_scan(GCproto *pt, BCPos from, BCPos to,
			uint8_t *rd, uint8_t *wr)
{
  const BCIns *bc = proto_bc(pt);
  BCReg fs = pt->framesize;
  BCPos i, e;
  BCReg sr;
#define RD(x) do { if (rd && (x) < fs) rd[x] = 1; } while (0)
#define WR(x) do { if (wr && (x) < fs) wr[x] = 1; } while (0)
  for (i = from; i < to && i < pt->sizebc; i++) {
    BCIns ins = bc[i];
    BCOp op = bc_op(ins);
    switch (bcmode_b(op)) {
    case BCMvar: RD(bc_b(ins)); break;
    default: break;
    }
    switch (bcmode_c(op)) {
    case BCMvar: RD(bc_c(ins)); break;
    case BCMrbase:  /* Only BC_CAT uses RC rbase: operands B..C. */
      for (sr = bc_b(ins); sr <= bc_c(ins); sr++) RD(sr);
      break;
    default: break;
    }
    switch (bcmode_a(op)) {
    case BCMvar: RD(bc_a(ins)); break;
    case BCMdst:  /* ISTC/ISFC only copy conditionally: not a write. */
      if (op != BC_ISTC && op != BC_ISFC) WR(bc_a(ins));
      break;
    case BCMbase:
      if (op >= BC_CALLM && op <= BC_ITERN) {
	BCReg top = (op == BC_CALLM || op == BC_CALLMT || bc_c(ins) == 0) ?
	  fs : (BCReg)(bc_a(ins) + bc_c(ins) + LJ_FR2);
	sr = bc_a(ins) - ((op == BC_ITERC || op == BC_ITERN) ? 3 : 0);
	for (; sr < top; sr++) RD(sr);
      } else if (op == BC_TSETM) {
	for (sr = bc_a(ins) - 1; sr < fs; sr++) RD(sr);
      }
      break;
    default: break;
    }
    /* A closure reads the parent slots it captures (as upvalues). */
    if (op == BC_FNEW) {
      GCproto *cpt = gco2pt(proto_kgc(pt, ~(ptrdiff_t)bc_d(ins)));
      const uint16_t *uv = proto_uv(cpt);
      MSize j;
      for (j = 0; j < cpt->sizeuv; j++)
	if ((uv[j] & PROTO_UV_LOCAL)) RD((BCReg)(uv[j] & 0xff));
    }
    /* Loop control slots are read by the FORI/FORL/ITERL bytecode itself. */
    if (op == BC_FORI || op == BC_JFORI) {
      for (sr = bc_a(ins); sr < bc_a(ins) + 3; sr++) RD(sr);
    } else if (op >= BC_FORL && op <= BC_JFORL) {
      for (e = bc_a(ins) + FORL_EXT + 1, sr = bc_a(ins); sr < e; sr++) RD(sr);
    } else if (op >= BC_ITERL && op <= BC_JITERL) {
      for (e = bc_a(ins) + 4, sr = bc_a(ins); sr < e; sr++) RD(sr);
    } else if (bc_isret(op)) {
      BCReg top = (op == BC_RETM) ? fs : (BCReg)(bc_a(ins) + bc_d(ins));
      for (sr = bc_a(ins); sr < top; sr++) RD(sr);
    }
    if (op == BC_KNIL)
      for (sr = bc_a(ins); sr <= bc_d(ins); sr++) WR(sr);
  }
#undef RD
#undef WR
}

static void gc_jit_cleardead(global_State *g, lua_State *L, TraceNo traceno)
{
  jit_State *J = G2J(g);
  GCtrace *T;
  lj_assertG(traceno > 0 && traceno < J->sizetrace,
	     "bad trace number %d in GC step", (int)traceno);
  if (!(traceno > 0 && traceno < J->sizetrace))
    return;
  T = traceref(J, traceno);
  lj_assertG(T != NULL, "no trace %d in GC step", (int)traceno);
  if (T == NULL)
    return;
  if (T->root != 0 && (T = traceref(J, T->root)) == NULL)
    return;
  {
    GCproto *pt = gco2pt(gcref(T->startpt));
    const BCIns *startpc = mref(T->startpc, const BCIns);
    const BCIns *bc = proto_bc(pt);
    BCPos startpos = proto_bcpos(pt, startpc);
    BCPos i, back = NO_JMP, bstart = startpos;
    BCReg nlive = 0, fs = pt->framesize;
    uint8_t rd[LJ_MAX_SLOTS], wr[LJ_MAX_SLOTS], ra[LJ_MAX_SLOTS];
    BCReg s, top = (BCReg)(L->top - L->base);
    BCOp sop = bc_op(T->startins);
    if (top > fs) top = fs;
    /* Find the loop back edge and the live lower bound of its control
    ** slots. A trace starts at the first bytecode of the loop body, which
    ** is not necessarily the loop instruction. */
    if (sop >= BC_LOOP && sop <= BC_JLOOP) {
      nlive = bc_a(T->startins);
      bstart = startpos + 1;
    }
    for (i = startpos + 1; i < pt->sizebc; i++) {
      BCOp op = bc_op(bc[i]);
      if (op >= BC_FORL && op <= BC_JFORL) {
	back = i; nlive = bc_a(bc[i]) + FORL_EXT + 1; break;
      }
      if (op >= BC_ITERL && op <= BC_JITERL) {
	back = i; nlive = bc_a(bc[i]) + 4; break;
      }
      if (op == BC_JMP) {
	ptrdiff_t tgt = (ptrdiff_t)i + 1 + bc_j(bc[i]);
	if (tgt <= (ptrdiff_t)startpos) {
	  back = i;
	  if (tgt >= 0 && bc_op(bc[tgt]) >= BC_LOOP && bc_op(bc[tgt]) <= BC_JLOOP)
	    nlive = bc_a(bc[tgt]);
	  break;
	}
      }
      if (bc_isret(op)) return;  /* A return before any back edge: not a loop. */
    }
    if (back == NO_JMP) return;
    memset(rd, 0, fs); memset(wr, 0, fs); memset(ra, 0, fs);
    gc_jit_scan(pt, bstart, back + 1, rd, wr);
    /* Reads outside the body: after the back edge, and before the start pc
    ** (an enclosing loop runs that code again after this loop exits). */
    gc_jit_scan(pt, 0, bstart, ra, NULL);
    gc_jit_scan(pt, back + 1, pt->sizebc, ra, NULL);
    for (s = 0; s < top; s++) {
      GCobj *uv;
      /* Slots at and above the loop's own registers are dead at the head.
      ** Below them, a slot written in the body and read by no bytecode of
      ** the function (and captured by no closure) is dead there too: the
      ** trace keeps the stored value in a register, so the stack slot still
      ** holds the stale one. */
      int dead = (sop >= BC_LOOP && sop <= BC_JLOOP && s >= nlive) ||
	 (wr[s] && !rd[s] && !ra[s]);
      if (dead)
	for (uv = gcref(L->openupval); uv != NULL; uv = gcnext(uv))
	  if (uvval(gco2uv(uv)) == L->base + s) { dead = 0; break; }
      if (dead) setnilV(L->base + s);
    }
  }
}

int LJ_FASTCALL lj_gc_step_jit(global_State *g, uint64_t pak)
{
  lua_State *L = gco2th(gcref(g->cur_L));
  MSize steps = (MSize)(pak >> 32);
  L->base = tvref(G(L)->jit_base);
  L->top = curr_topL(L);
  if (((pak >> 16) & 0xffff))  /* GC check at the start bytecode. */
    gc_jit_cleardead(g, L, (TraceNo)(pak & 0xffff));
  while (steps-- > 0 && lj_gc_step(L) == 0)
    ;
  /* Return 1 to force a trace exit. */
  return (G(L)->gc.state == GCSatomic || G(L)->gc.state == GCSfinalize);
}
#else
/* 32-bit targets keep the 2-argument call and do not clear dead slots. */
int LJ_FASTCALL lj_gc_step_jit(global_State *g, MSize steps)
{
  lua_State *L = gco2th(gcref(g->cur_L));
  L->base = tvref(G(L)->jit_base);
  L->top = curr_topL(L);
  while (steps-- > 0 && lj_gc_step(L) == 0)
    ;
  /* Return 1 to force a trace exit. */
  return (G(L)->gc.state == GCSatomic || G(L)->gc.state == GCSfinalize);
}
#endif
#endif

/* Perform a full GC cycle. */
void lj_gc_fullgc(lua_State *L)
{
  global_State *g = G(L);
  int32_t ostate = g->vmstate;
#ifdef LUAJIT_GC_STATS
  uint64_t gcstats_t0 = gcstats_now();
#endif
  setvmstate(g, GC);
  if (g->gc.state <= GCSatomic) {  /* Caught somewhere in the middle. */
    setmref(g->gc.sweep, &g->gc.root);  /* Sweep everything (preserving it). */
    setgcrefnull(g->gc.gray);  /* Reset lists from partial propagation. */
    setgcrefnull(g->gc.grayagain);
    setgcrefnull(g->gc.weak);
    g->gc.state = GCSsweepstring;  /* Fast forward to the sweep phase. */
    g->gc.sweepstr = 0;
  }
  while (g->gc.state == GCSsweepstring || g->gc.state == GCSsweep)
    gc_onestep(L);  /* Finish sweep. */
  lj_assertG(g->gc.state == GCSfinalize || g->gc.state == GCSpause,
	     "bad GC state");
  /* Now perform a full GC. */
  g->gc.state = GCSpause;
  do { gc_onestep(L); } while (g->gc.state != GCSpause);
  g->gc.threshold = (g->gc.estimate/100) * (g->gc.pause * 4);
  g->vmstate = ostate;
#ifdef LUAJIT_GC_STATS
  gcstats_pause();
  {
    uint64_t dt = gcstats_now() - gcstats_t0;
    gcstats.fullgc++; gcstats.cycles++;
    gcstats.full_ns += dt;
    if (dt > gcstats.full_max_ns) gcstats.full_max_ns = dt;
    gcstats_add(gcstats.full_hist, dt);
  }
#endif
}

/* -- Write barriers ------------------------------------------------------ */

/* Move the GC propagation frontier forward. */
void lj_gc_barrierf(global_State *g, GCobj *o, GCobj *v)
{
  lj_assertG(isblack(o) && iswhite(v) && !isdead(g, v) && !isdead(g, o),
	     "bad object states for forward barrier");
  lj_assertG(g->gc.state != GCSfinalize && g->gc.state != GCSpause,
	     "bad GC state");
  lj_assertG(o->gch.gct != ~LJ_TTAB, "barrier object is not a table");
  /* Preserve invariant during propagation. Otherwise it doesn't matter. */
  if (g->gc.state == GCSpropagate || g->gc.state == GCSatomic)
    gc_mark(g, v);  /* Move frontier forward. */
  else
    makewhite(g, o);  /* Make it white to avoid the following barrier. */
}

/* Specialized barrier for closed upvalue. Pass &uv->tv. */
void LJ_FASTCALL lj_gc_barrieruv(global_State *g, TValue *tv)
{
#define TV2MARKED(x) \
  (*((uint8_t *)(x) - offsetof(GCupval, tv) + offsetof(GCupval, marked)))
  if (g->gc.state == GCSpropagate || g->gc.state == GCSatomic)
    gc_mark(g, gcV(tv));
  else
    TV2MARKED(tv) = (TV2MARKED(tv) & (uint8_t)~LJ_GC_COLORS) | curwhite(g);
#undef TV2MARKED
}

/* Close upvalue. Also needs a write barrier. */
void lj_gc_closeuv(global_State *g, GCupval *uv)
{
  GCobj *o = obj2gco(uv);
  /* Copy stack slot to upvalue itself and point to the copy. */
  copyTV(mainthread(g), &uv->tv, uvval(uv));
  setmref(uv->v, &uv->tv);
  uv->closed = 1;
  setgcrefr(o->gch.nextgc, g->gc.root);
  setgcref(g->gc.root, o);
  if (isgray(o)) {  /* A closed upvalue is never gray, so fix this. */
    if (g->gc.state == GCSpropagate || g->gc.state == GCSatomic) {
      gray2black(o);  /* Make it black and preserve invariant. */
      if (tviswhite(&uv->tv))
	lj_gc_barrierf(g, o, gcV(&uv->tv));
    } else {
      makewhite(g, o);  /* Make it white, i.e. sweep the upvalue. */
      lj_assertG(g->gc.state != GCSfinalize && g->gc.state != GCSpause,
		 "bad GC state");
    }
  }
}

#if LJ_HASJIT
/* Mark a trace if it's saved during the propagation phase. */
void lj_gc_barriertrace(global_State *g, uint32_t traceno)
{
  if (g->gc.state == GCSpropagate || g->gc.state == GCSatomic)
    gc_marktrace(g, traceno);
}
#endif

/* -- Allocator ----------------------------------------------------------- */

/* Call pluggable memory allocator to allocate or resize a fragment. */
void *lj_mem_realloc(lua_State *L, void *p, GCSize osz, GCSize nsz)
{
  global_State *g = G(L);
  lj_assertG((osz == 0) == (p == NULL), "realloc API violation");
#ifdef LUAJIT_GC_STATS
  GCSTATS_ALLOC_OPEN();
#endif
  p = g->allocf(g->allocd, p, osz, nsz);
#ifdef LUAJIT_GC_STATS
  GCSTATS_ALLOC_CLOSE();
  gcstats.alloc_calls++; gcstats.alloc_bytes += nsz;
#endif
  if (p == NULL && nsz > 0)
    lj_err_mem(L);
  lj_assertG((nsz == 0) == (p == NULL), "allocf API violation");
  lj_assertG(checkptrGC(p),
	     "allocated memory address %p outside required range", p);
  g->gc.total = (g->gc.total - osz) + nsz;
  return p;
}

/* Allocate new GC object and link it to the root set. */
void * LJ_FASTCALL lj_mem_newgco(lua_State *L, GCSize size)
{
  global_State *g = G(L);
  GCobj *o;
#ifdef LUAJIT_GC_STATS
  GCSTATS_ALLOC_OPEN();
#endif
  o = (GCobj *)g->allocf(g->allocd, NULL, 0, size);
#ifdef LUAJIT_GC_STATS
  GCSTATS_ALLOC_CLOSE();
  gcstats.alloc_calls++; gcstats.alloc_bytes += size;
#endif
  if (o == NULL)
    lj_err_mem(L);
  lj_assertG(checkptrGC(o),
	     "allocated memory address %p outside required range", o);
  g->gc.total += size;
  setgcrefr(o->gch.nextgc, g->gc.root);
  setgcref(g->gc.root, o);
  newwhite(g, o);
  return o;
}

/* Resize growable vector. */
void *lj_mem_grow(lua_State *L, void *p, MSize *szp, MSize lim, MSize esz)
{
  MSize sz = (*szp) << 1;
  if (sz < LJ_MIN_VECSZ)
    sz = LJ_MIN_VECSZ;
  if (sz > lim)
    sz = lim;
  p = lj_mem_realloc(L, p, (*szp)*esz, sz*esz);
  *szp = sz;
  return p;
}

