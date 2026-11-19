#!/usr/bin/env python3
"""Per-phase GC split (Stage 0b) for a selected workload set.

Runs the LUAJIT_GC_STATS build (tmp/gcstats/src/luajit, built by
tests/bench/gc-phase.sh) several times per workload and reports the median of
each per-phase timer.  Reuses gc_measure.py for corpus extraction, C-module
builds and child execution, so the workloads are the same ones the baseline
measured.

  GC_PHASE_ONLY=binary-trees,lpeg,...   workload filter (default: the four
                                        Stage 0b workloads)
  GC_PHASE_REPS=3                       repetitions per workload

Prints one human table per workload and a final `PHASERESULT {json}` line.
"""
import json
import os
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gc_measure as G  # noqa: E402

# (label, microseconds field, step-count field or None)
PHASES = [
    ("mark", "phase_mark_us", "phase_mark_steps"),
    ("atomic", "phase_atomic_us", None),
    ("sweepstr", "phase_sweepstr_us", "phase_sweepstr_steps"),
    ("sweep", "phase_sweep_us", "phase_sweep_steps"),
    ("finalize", "phase_finalize_us", "phase_finalize_steps"),
]
DEFAULT = "binary-trees,lpeg,k-nucleotide,lua-cjson"


def median_of(samples, key):
    vals = [s.get(key) for s in samples if s.get(key) is not None]
    return statistics.median(vals) if vals else None


def main():
    names = [n.strip() for n in os.environ.get("GC_PHASE_ONLY", DEFAULT).split(",") if n.strip()]
    reps = int(os.environ.get("GC_PHASE_REPS", "3"))
    stats_bin = str(G.OURS_STATS)
    if not Path(stats_bin).is_file():
        sys.exit("missing %s (build it first: sh tests/bench/gc-phase.sh)" % stats_bin)
    G.CORPUS.mkdir(parents=True, exist_ok=True)

    selected = {k: v for k, v in G.CORPUS_SPEC.items() if k in names}
    mods = {}
    if selected:
        G.ensure_corpus(selected)
        mods = G.build_cmods(selected)
    workloads = [{"name": n, "kind": "classic"} for n in names if n in G.CLASSIC]
    for wl in G.corpus_workloads(selected):
        if wl["name"] in names:
            workloads.append(wl)

    arm = ("ours-stats", "ours", [stats_bin, "-jon"])
    result = {}
    print("PHASE reps=%d workloads=%s" % (reps, ",".join(names)))
    for wl in workloads:
        samples = []
        walls, rsss = [], []
        for _ in range(reps):
            r = G.run_repetition(wl, arm, mods, 1800)
            g = r.get("gc") or G.parse_gcstats(r["stderr_tail"])
            if g:
                samples.append(g)
                walls.append(r["wall_ms"])
                rsss.append(r["maxrss_kb"])
        if not samples:
            print("PHASE %s: no GCSTATS captured" % wl["name"], flush=True)
            continue
        med = {k: median_of(samples, k) for k in samples[0]}
        total = sum((med.get(f) or 0.0) for _, f, _ in PHASES)
        step_total = med.get("step_total_us") or 0.0
        alloc_us = med.get("alloc_us") or 0.0
        alloc_calls = med.get("alloc_calls") or 0
        alloc_samples = med.get("alloc_samples") or 0
        alloc_est = (alloc_us / alloc_samples * alloc_calls) if alloc_samples else 0.0
        result[wl["name"]] = med
        print("\n### %s (%s)  n=%d  wall %.1f ms  peak RSS %.1f MB" %
              (wl["name"], wl["kind"], len(samples),
               statistics.median(walls), statistics.median(rsss) / 1024.0))
        print("| phase | us | % of phase total | steps |")
        print("|---|---:|---:|---:|")
        for label, field, stepf in PHASES:
            us = med.get(field) or 0.0
            pct = (100.0 * us / total) if total else 0.0
            steps = med.get(stepf) if stepf else None
            print("| %s | %.3f | %.1f %% | %s |" %
                  (label, us, pct, "-" if steps is None else "%d" % steps))
        print("| **total** | %.3f | 100 %% | step_total(raw) %.3f |" % (total, step_total))
        print("cycles=%s steps=%s full=%s | clock_ns=%s | alloc %s calls / %.1f MB |"
              " free %s calls / %.1f MB | sampled alloc %.3f us / %s calls -> est. %.1f us total" %
              (med.get("cycles"), med.get("steps"), med.get("full"),
               med.get("clock_ns"), alloc_calls, (med.get("alloc_kb") or 0) / 1024.0,
               med.get("free_calls"), (med.get("free_kb") or 0) / 1024.0,
               alloc_us, alloc_samples, alloc_est))
    print("\nPHASERESULT " + json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
