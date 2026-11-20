#!/usr/bin/env python3
"""A/B runner for the string-sweep prefetch: base vs head, one job, interleaved.

Reuses gc_measure.py for workload definitions, corpus setup and child
execution, so this is the same methodology as gc-measure.sh; the only change
is that the two arms are the base and head binaries built by gc-strsweep.sh
instead of the fixed baseline arms.  Arms are run A, B, A, B, ... with the same
adaptive repetition count.

Two modes:

  * the workload sweep (default): one row per workload, median over the
    repetitions, closing `ABRESULT {json}` line;
  * GC_AB_PAIRS=n: one workload repeated as n alternating pairs, the arm order
    swapped in every second pair so within-job drift cancels; reports how many
    pairs the head arm won and the paired deltas.

  GC_AB_ONLY=name[,name]   workload filter (default: the classic set + lua-cjson + lpeg)
  GC_AB_PAIRS=n            alternating-pairs mode for GC_AB_PAIR_WORK (default 0)
  GC_AB_PAIR_WORK=name     workload for the pairs mode (default k-nucleotide)

Prints the tables and a final `ABRESULT {json}` line.
"""
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gc_measure as G  # noqa: E402

BASE = G.ROOT / "tmp" / "gc-alt-base" / "src" / "luajit"
HEAD = G.ROOT / "tmp" / "gc-alt-head" / "src" / "luajit"
DEFAULT = ("nbody,spectral-norm,fannkuch-redux,binary-trees,fasta,deltablue,"
           "scimark,k-nucleotide,regex-dna,lua-cjson,lpeg")


def pair_run(wl, arms, mods, pairs):
    """Run one workload as alternating pairs; return the pair statistics."""
    rows = []
    for i in range(pairs):
        order = arms if i % 2 == 0 else list(reversed(arms))
        r = {}
        for arm in order:
            r[arm[0]] = G.run_repetition(wl, arm, mods, 600)
        b, h = r["base"]["wall_ms"], r["head"]["wall_ms"]
        rows.append({"i": i, "order": "".join(a[0][0].upper() for a in order),
                     "base_ms": b, "head_ms": h, "delta_pct": 100.0 * (h - b) / b})
    wins = sum(1 for x in rows if x["head_ms"] < x["base_ms"])
    print("| pair | order | base ms | head ms | delta |")
    print("|---:|:-:|---:|---:|---:|")
    for x in rows:
        print("| %d | %s | %.2f | %.2f | %+.2f%% |" %
              (x["i"], x["order"], x["base_ms"], x["head_ms"], x["delta_pct"]))
    med_b = G.median([x["base_ms"] for x in rows])
    med_h = G.median([x["head_ms"] for x in rows])
    print("PAIRS %s: %d pairs, head faster in %d/%d, median %.2f -> %.2f ms (%+.2f%%)" %
          (wl["name"], pairs, wins, pairs, med_b, med_h, 100.0 * (med_h - med_b) / med_b))
    return {"pairs": pairs, "head_wins": wins, "median_base_ms": med_b,
            "median_head_ms": med_h, "raw": rows}


def main():
    names = [n.strip() for n in os.environ.get("GC_AB_ONLY", DEFAULT).split(",") if n.strip()]
    for b in (BASE, HEAD):
        if not Path(b).is_file():
            sys.exit("missing %s (build it first: sh tests/bench/gc-strsweep.sh)" % b)
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

    arms = [("base", "ours", [str(BASE), "-jon"]), ("head", "ours", [str(HEAD), "-jon"])]
    if os.environ.get("GC_AB_SWAP", "0") == "1":
        arms.reverse()  # control for within-repetition drift (arm order bias)
    print("AB base=%s head=%s" % (BASE, HEAD))
    print("| workload | base ms | head ms | delta | base RSS MB | head RSS MB | reps |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    out = {}
    for wl in workloads:
        runs, _ = G.measure(wl, arms, [], mods)
        s = G.summarize(wl["name"], wl["kind"], runs, {}, arms)
        b, h = s["rows"]["base"], s["rows"]["head"]
        if b["wall_ms"] is None or h["wall_ms"] is None:
            continue
        d = h["wall_ms"] - b["wall_ms"]
        pct = 100.0 * d / b["wall_ms"]
        out[wl["name"]] = {
            "base_ms": b["wall_ms"], "head_ms": h["wall_ms"], "delta_pct": pct,
            "base_rss_kb": b["maxrss_kb"], "head_rss_kb": h["maxrss_kb"],
            "n": b["n"], "base_raw": b["raw_ms"], "head_raw": h["raw_ms"],
        }
        print("| %s | %.1f | %.1f | %+.1f (%+.2f%%) | %.1f | %.1f | %d |" %
              (wl["name"], b["wall_ms"], h["wall_ms"], d, pct,
               b["maxrss_kb"] / 1024.0, h["maxrss_kb"] / 1024.0, b["n"]))

    pairs = int(os.environ.get("GC_AB_PAIRS", "0") or 0)
    if pairs > 0:
        pname = os.environ.get("GC_AB_PAIR_WORK", "k-nucleotide").strip()
        wl = next((w for w in workloads if w["name"] == pname), None)
        if wl is None:
            sys.exit("pairs mode: workload %s is not selected (GC_AB_ONLY)" % pname)
        out["pairs_" + pname] = pair_run(wl, arms, mods, pairs)

    print("\nABRESULT " + json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
