#!/usr/bin/env python3
"""Patch a PUC-Lua 5.4.9 source tree with optional GC counters.

The patch is for measurement builds only (compiled with -DLUA_GC_STATS); it
adds the same kind of counters as the LuaJIT block: step/atomic duration
histograms, completed cycles, minor/major counts in generational mode, dumped
once to stderr at process exit as a GCSTATS line.  It is applied to a scratch
copy of the reference tree, never to tests/ref itself.
"""
import sys
from pathlib import Path

BLOCK = r'''
/* Measurement-only GC counters (LUA_GC_STATS). */
#ifdef LUA_GC_STATS
#include <stdint.h>
#include <sys/time.h>

typedef struct PUCGCStats {
  uint64_t steps, cycles, full, minor, major, atomic_calls;
  uint64_t step_ns, step_max_ns, atomic_ns, atomic_max_ns;
  uint32_t step_hist[64], atomic_hist[64];
} PUCGCStats;

static PUCGCStats gcstats;

static uint64_t gcstats_now(void)
{
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull;
}

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
  fprintf(stderr,
    "GCSTATS steps=%llu cycles=%llu full=%llu atomic=%llu minor=%llu major=%llu "
    "step_total_us=%.3f step_p50_us=%.3f step_p99_us=%.3f step_max_us=%.3f "
    "atomic_total_us=%.3f atomic_p50_us=%.3f atomic_p99_us=%.3f atomic_max_us=%.3f\n",
    (unsigned long long)gcstats.steps, (unsigned long long)gcstats.cycles,
    (unsigned long long)gcstats.full, (unsigned long long)gcstats.atomic_calls,
    (unsigned long long)gcstats.minor, (unsigned long long)gcstats.major,
    (double)gcstats.step_ns / 1000.0,
    gcstats_pct(gcstats.step_hist, gcstats.steps, 0.50),
    gcstats_pct(gcstats.step_hist, gcstats.steps, 0.99),
    (double)gcstats.step_max_ns / 1000.0,
    (double)gcstats.atomic_ns / 1000.0,
    gcstats_pct(gcstats.atomic_hist, gcstats.atomic_calls, 0.50),
    gcstats_pct(gcstats.atomic_hist, gcstats.atomic_calls, 0.99),
    (double)gcstats.atomic_max_ns / 1000.0);

}

#define GCSTATS_STEP_DONE() do { \
  uint64_t _t = gcstats_now() - gcstats_t0; \
  gcstats.steps++; gcstats.step_ns += _t; \
  if (_t > gcstats.step_max_ns) gcstats.step_max_ns = _t; \
  gcstats_add(gcstats.step_hist, _t); \
} while (0)
#define GCSTATS_ATOMIC_WORK(w) do { \
  uint64_t _t0 = gcstats_now(); \
  (w) = atomic(L); \
  uint64_t _t = gcstats_now() - _t0; \
  gcstats.atomic_calls++; gcstats.atomic_ns += _t; \
  if (_t > gcstats.atomic_max_ns) gcstats.atomic_max_ns = _t; \
  gcstats_add(gcstats.atomic_hist, _t); \
} while (0)
#endif
'''

REPL = [
    ('#include "ltm.h"\n', '#include "ltm.h"\n' + BLOCK),
    ('''    case GCSenteratomic: {
      work = atomic(L);  /* work is what was traversed by 'atomic' */''',
     '''    case GCSenteratomic: {
#ifdef LUA_GC_STATS
      GCSTATS_ATOMIC_WORK(work);
#else
      work = atomic(L);  /* work is what was traversed by 'atomic' */
#endif'''),
    ('''  if (g->gcstate == GCSpause)
    setpause(g);  /* pause until next cycle */''',
     '''  if (g->gcstate == GCSpause) {
    setpause(g);  /* pause until next cycle */
#ifdef LUA_GC_STATS
    gcstats.cycles++;
#endif
  }'''),
    ('''      lu_mem numobjs = fullgen(L, g);  /* do a major collection */''',
     '''      lu_mem numobjs = fullgen(L, g);  /* do a major collection */
#ifdef LUA_GC_STATS
      gcstats.major++; gcstats.full++; gcstats.cycles++;
#endif'''),
    ('''    else {  /* regular case; do a minor collection */
      youngcollection(L, g);''',
     '''    else {  /* regular case; do a minor collection */
      youngcollection(L, g);
#ifdef LUA_GC_STATS
      gcstats.minor++; gcstats.cycles++;
#endif'''),
    ('''void luaC_step (lua_State *L) {
  global_State *g = G(L);
  if (!gcrunning(g))  /* not running? */
    luaE_setdebt(g, -2000);
  else {
    if(isdecGCmodegen(g))
      genstep(L, g);
    else
      incstep(L, g);
  }
}''',
     '''void luaC_step (lua_State *L) {
  global_State *g = G(L);
#ifdef LUA_GC_STATS
  uint64_t gcstats_t0 = gcstats_now();
#endif
  if (!gcrunning(g))  /* not running? */
    luaE_setdebt(g, -2000);
  else {
    if(isdecGCmodegen(g))
      genstep(L, g);
    else
      incstep(L, g);
  }
#ifdef LUA_GC_STATS
  GCSTATS_STEP_DONE();
#endif
}'''),
]


def main():
    root = Path(sys.argv[1])
    p = root / "src" / "lgc.c"
    text = p.read_text()
    for old, new in REPL:
        if old not in text:
            sys.exit("puc_gc_stats: anchor not found: %r" % old[:60])
        text = text.replace(old, new, 1)
    p.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
