#!/usr/bin/env python3
"""Interleaved classic-set timing: stock LuaJIT 2.1 vs this fork, one job.

Reuses tests/bench/classic/run.py for the pinned sources and the stock build,
but alternates the two arms per repetition (interleaved) and reports the
median of BENCH_REPS (default 7) runs per arm.

  x64-box -t 3600 python3 tests/bench/classic/run-interleaved.py

(x64-box is a private wrapper that runs a command on a remote x86_64 test
host; pin one host, so that both arms run on the same machine.)
"""
import importlib.util, os, statistics, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("classicrun", HERE / "run.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

REPS = int(os.environ.get("BENCH_REPS", "7"))


def run_one(binpath, cwd, argv, stdin_file):
    stdin = open(stdin_file, "rb") if stdin_file else subprocess.DEVNULL
    try:
        t0 = time.monotonic()
        subprocess.run([binpath] + argv, cwd=cwd, stdin=stdin,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=600)
        return (time.monotonic() - t0) * 1000.0
    finally:
        if stdin_file:
            stdin.close()


def main():
    cr.check_pins()
    cr.extract_sources()
    cr.build_stock()
    stock = str(cr.STOCK / "src" / "luajit")
    ours = str(cr.OURS)
    if not Path(ours).is_file():
        sys.exit("need src/luajit (build first)")
    rows = []
    for name, (script, argv, stdin_name, compare) in cr.BENCHES.items():
        cwd = cr.SRC / "deltablue" if name == "deltablue" else cr.SRC
        stdin_file = str(cr.BENCH / stdin_name) if stdin_name else None
        vals = {"stock": [], "ours": []}
        print("=== %s (%d reps, interleaved) ===" % (name, REPS), flush=True)
        for rep in range(REPS):
            for arm, binpath in (("stock", stock), ("ours", ours)):
                ms = run_one(binpath, cwd, [script] + argv, stdin_file)
                vals[arm].append(ms)
                print("  rep%d %-5s %.1f" % (rep, arm, ms), flush=True)
        sm = statistics.median(vals["stock"])
        om = statistics.median(vals["ours"])
        ratio = sm / om
        rows.append((name, sm, om, ratio))
        print("%-14s stock_med=%8.1f ours_med=%8.1f stock/ours=%6.3f" %
              (name, sm, om, ratio), flush=True)
    print("\n| benchmark | stock ms | ours ms | stock/ours |")
    print("|---|---:|---:|---:|")
    for name, sm, om, ratio in rows:
        print("| %s | %.1f | %.1f | %.3f |" % (name, sm, om, ratio))
    bad = [r for r in rows if r[3] < 0.95]
    print("\nBELOW 0.95:", ", ".join("%s=%.3f" % (r[0], r[3]) for r in bad) or "none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
