#!/usr/bin/env python3
"""Interleaved stock-vs-ours measurement for one classic benchmark.
Untracked scratch; not part of any commit."""
import os, sys, time, statistics, subprocess
from pathlib import Path

sys.path.insert(0, "tests/bench/classic")
import run as R  # noqa: E402

name = os.environ.get("BENCH_NAME", "spectral-norm")
script, argv, stdin_name, _cmp = R.BENCHES[name]
reps = int(os.environ.get("REPS", "7"))

R.check_pins(); R.extract_sources(); R.build_stock()
stock = R.STOCK / "src" / "luajit"
ours = R.OURS
cwd = R.SRC / "deltablue" if name == "deltablue" else R.SRC
stdin_file = str(R.BENCH / stdin_name) if stdin_name else None

def run(exe):
    stdin = open(stdin_file, "rb") if stdin_file else subprocess.DEVNULL
    t0 = time.monotonic()
    p = subprocess.run([str(exe), "-jon", script] + argv, cwd=cwd, stdin=stdin,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    dt = (time.monotonic() - t0) * 1000.0
    if stdin_file: stdin.close()
    if p.returncode: sys.exit("run failed: %s" % p.stderr.decode()[-300:])
    return dt

sv, ov = [], []
for i in range(reps):
    sv.append(run(stock)); ov.append(run(ours))
sm, om = statistics.median(sv), statistics.median(ov)
print("%s: stock median %.1f ms, ours median %.1f ms, stock/ours %.3f" %
      (name, sm, om, sm / om))
print("  stock:", " ".join("%.1f" % v for v in sv))
print("  ours :", " ".join("%.1f" % v for v in ov))
