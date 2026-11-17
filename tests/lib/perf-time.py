#!/usr/bin/env python3
"""Median wall times for one classic benchmark under -jon/-joff, stock vs ours."""
import os, subprocess, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "bench" / "classic"))
import run as br
B, SRC = br.BENCH, br.SRC
STOCK = br.STOCK / "src" / "luajit"; OURS = ROOT / "src" / "luajit"

def one(binary, name, opt, reps=3):
    script, argv, stdin, _ = br.BENCHES[name]
    cwd = SRC / "deltablue" if name == "deltablue" else SRC
    vals = []
    for _ in range(reps):
        fin = open(B / stdin, "rb") if stdin else subprocess.DEVNULL
        t0 = time.monotonic()
        try:
            p = subprocess.run([str(binary), opt, script] + argv, cwd=cwd, stdin=fin,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=600)
        finally:
            if stdin: fin.close()
        if p.returncode: print("ERR", binary, opt, p.stderr[:300]); return None
        vals.append((time.monotonic()-t0)*1000)
    vals.sort(); return vals[len(vals)//2]

def main():
    br.check_pins(); br.extract_sources(); br.build_stock()
    for name in sys.argv[1:] or ["k-nucleotide"]:
        print("###", name)
        for opt in ("-jon", "-joff"):
            s = one(STOCK, name, opt); o = one(OURS, name, opt)
            print("%-16s stock=%8.1f ours=%8.1f stock/ours=%s" %
                  (name + " " + opt, s or 0, o or 0, ("%.3f" % (s/o)) if s and o else "-"))
if __name__ == "__main__": sys.exit(main())
