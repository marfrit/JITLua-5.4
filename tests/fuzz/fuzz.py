#!/usr/bin/env python3
"""Differential fuzz driver (MISSION Phase 0 deliverable 3).

  tests/fuzz/fuzz.py --seed 1 --count 200 --mode B --opt-levels 0,1,2,3 --gc
  tests/fuzz/fuzz.py --seed 1 --count 50 --mode A          # vs PUC 5.4.9
  tests/fuzz/fuzz.py --seed 1 --count 50 --mode R          # dump -> reload -> rerun

Reproducible: program N is generated from seed (base_seed + N).  Any mismatch is
saved under tests/fuzz/failures/<seed>-<mode>/ together with a repro command;
commit those seeds to the corpus (MISSION §7.3).
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import runner  # noqa: E402

GEN = ROOT / "tests" / "fuzz" / "gen.py"
FAILDIR = ROOT / "tests" / "fuzz" / "failures"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--mode", default="B", choices=["A", "B", "R"])
    ap.add_argument("--gen-mode", default="mixed")
    ap.add_argument("--gc", action="store_true")
    ap.add_argument("--stmts", type=int, default=18)
    ap.add_argument("--opt-levels", default=None)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--luajit", default=str(ROOT / "src" / "luajit"))
    ap.add_argument("--ref", default=str(ROOT / "tests" / "ref" / "bin" / "lua54ref"))
    ap.add_argument("--luac", default=str(ROOT / "tests" / "ref" / "bin" / "luac54ref"))
    ap.add_argument("--out", default=str(ROOT / "tests" / "fuzz" / "out"))
    ap.add_argument("--stop-on-fail", action="store_true")
    a = ap.parse_args()

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    levels = a.opt_levels.split(",") if a.opt_levels else [None]
    stats = {"pass": 0, "fail": 0, "invalid": 0, "timeout": 0}
    failures = []

    for n in range(a.count):
        seed = a.seed + n
        prog = out / ("fuzz-%d.lua" % seed)
        subprocess.run([sys.executable, str(GEN), "--seed", str(seed), "--mode", a.gen_mode,
                        "--stmts", str(a.stmts), "--out", str(prog)] + (["--gc"] if a.gc else []),
                       check=True)
        # The generator must emit valid 5.4: a program the reference cannot parse
        # is a generator bug, not an implementation difference.
        rc, o, e, to = runner.run([a.luac, "-p", prog.name], prog.parent, a.timeout)
        if rc != 0:
            stats["invalid"] += 1
            print("INVALID seed=%d: %s" % (seed, runner.canon_err(e)[:200]))
            continue
        for lv in levels:
            tag = a.mode + ("" if lv is None else "@" + lv)
            if a.mode == "A":
                x = runner.run([a.ref, prog.name], prog.parent, a.timeout)
                y = runner.run([a.luajit, "-joff", prog.name], prog.parent, a.timeout)
            elif a.mode == "B":
                on = [a.luajit, "-jon"] + (["-O" + lv] if lv else [])
                x = runner.run(on + [prog.name], prog.parent, a.timeout)
                y = runner.run([a.luajit, "-joff", prog.name], prog.parent, a.timeout)
            else:
                x = runner.run([a.luajit, "-joff", prog.name], prog.parent, a.timeout)
                y = runner.run([a.luajit, "-joff", str(ROOT / "tests/lib/dump_reload.lua"), prog.name],
                               prog.parent, a.timeout)
            if x[3] and y[3]:
                stats["timeout"] += 1
                continue
            bad, detail = runner.compare(x, y, "x", "y")
            if not bad:
                stats["pass"] += 1
                continue
            stats["fail"] += 1
            d = FAILDIR / ("%d-%s" % (seed, tag.replace("@", "-")))
            d.mkdir(parents=True, exist_ok=True)
            (d / "prog.lua").write_text(prog.read_text())
            (d / "detail.txt").write_text(detail)
            (d / "x.txt").write_text("rc=%d\n--stdout--\n%s\n--stderr--\n%s" % (x[0], x[1], x[2]))
            (d / "y.txt").write_text("rc=%d\n--stdout--\n%s\n--stderr--\n%s" % (y[0], y[1], y[2]))
            repro = ("tests/fuzz/gen.py --seed %d --mode %s --stmts %d%s --out /tmp/p.lua"
                     % (seed, a.gen_mode, a.stmts, " --gc" if a.gc else ""))
            (d / "repro.sh").write_text("#!/bin/sh\n%s\n" % repro)
            failures.append((seed, tag, str(d)))
            print("FAIL seed=%d mode=%s -> %s" % (seed, tag, d))
            if a.stop_on_fail:
                break
        if a.stop_on_fail and failures:
            break

    print("== fuzz summary ==")
    print("  seed base %d, count %d, mode %s, levels %s, gc %s"
          % (a.seed, a.count, a.mode, ",".join(l or "default" for l in levels), a.gc))
    for k in ("pass", "fail", "invalid", "timeout"):
        print("  %-8s %d" % (k, stats[k]))
    if failures:
        print("  failing seeds: %s" % ", ".join(str(f[0]) for f in failures))
    return 1 if (stats["fail"] or stats["invalid"]) else 0


if __name__ == "__main__":
    sys.exit(main())
