#!/usr/bin/env python3
"""Stop-point triage for one vendored PUC 5.4.9 suite file.

The harness compares whole files, so a suite file that stops at an assertion
hides everything behind that assertion. This driver finds every stop point of
one file in a single pass: it runs the file in three arms (PUC 5.4.9, our
binary with -joff and with -jon), and after each failure it comments the failing
assert out *in a scratch copy* and runs that arm again. Nothing in
tests/corpus is ever modified, and no arm is expected to pass -- the point is
the list of stop points to classify.

    python3 tests/lib/suite-triage.py tests/corpus/puc54/gengc.lua
    python3 tests/lib/suite-triage.py --timeout 300 tests/corpus/puc54/gc.lua

A suite file that needs the internal test library T runs here exactly as the
harness runs it: neither arm defines T, so `assert(not T or ...)` blocks and
`if T == nil then ... return end` are dead code in both arms.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ERR_RE = re.compile(r":(\d+): (assertion failed!|attempt to .*|bad \w+.*|"
                    r"stack overflow|not enough memory|too many[^.]*)", re.M)


def env():
    e = dict(os.environ)
    e.update({"LC_ALL": "C", "TZ": "UTC",
              "LUA_PATH": "./?.lua;./?/init.lua",
              "LUA_CPATH": "./libs/?.so;?.so"})
    for k in ("LUAJIT_OPT", "LUA_INIT", "LUA_INIT_5_4"):
        e.pop(k, None)
    return e


def arm_runs(label, argv, lines, scratch, opts):
    """Run the mutated copy in one arm until it stops passing; return the list
    of (line, source) it stopped at."""
    print("\n===== arm %s =====" % label, flush=True)
    lines = list(lines)
    stops, n = [], 0
    while True:
        n += 1
        f = Path(scratch) / "case.lua"
        f.write_text("\n".join(lines))
        try:
            p = subprocess.run(argv + [str(f)], cwd=scratch, env=env(),
                               timeout=opts.timeout, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
        except subprocess.TimeoutExpired:
            print("run %d: TIMEOUT after %s s -- no further stop point"
                  % (n, opts.timeout))
            return stops
        rc, out, err = p.returncode, p.stdout.decode("utf-8", "replace"), \
            p.stderr.decode("utf-8", "replace")
        print("run %d: exit %d" % (n, rc))
        for ln in (out + "\n" + err).split("\n"):
            if ln.strip():
                print("   | %s" % ln)
        m = ERR_RE.search(err)
        if rc == 0 or not m or n > opts.max_mutations:
            return stops
        lineno = int(m.group(1))
        src = lines[lineno - 1] if 0 < lineno <= len(lines) else ""
        if not re.match(r"\s*assert\s*\(", src):
            print("   --> line %d is not an assert, stopping here: %s"
                  % (lineno, src.strip()))
            return stops
        print("   --> commenting out line %d: %s" % (lineno, src.strip()))
        stops.append((lineno, src.strip()))
        lines[lineno - 1] = "-- TRIAGE: assert commented out to reach the next one" \
            + src[src.index("assert"):]
        sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*",
                    default=["tests/corpus/puc54/gengc.lua"],
                    help="suite file relative to the repo root")
    ap.add_argument("--luajit", default=str(ROOT / "src" / "luajit"))
    ap.add_argument("--ref", default=str(ROOT / "tests" / "ref" / "bin" / "lua54ref"))
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--max-mutations", type=int, default=40,
                    help="stop after this many commented-out asserts per arm")
    opts = ap.parse_args()
    luajit, ref = Path(opts.luajit), Path(opts.ref)
    if not luajit.exists():
        sys.exit("error: %s not found -- run 'make -j8' in the repo root" % luajit)
    if not ref.exists():
        sys.exit("error: %s not found -- run tests/ref/fetch-ref.sh" % ref)
    summary = []
    for rel in opts.files:
        path = ROOT / rel
        if not path.exists():
            sys.exit("error: no such file %s" % path)
        lines = path.read_text(errors="replace").split("\n")
        scratch = tempfile.mkdtemp(prefix="suite-triage-")
        # Neighbouring files of the suite file stay reachable (dofile/require).
        for sib in path.parent.iterdir():
            try:
                os.symlink(str(sib), os.path.join(scratch, sib.name))
            except OSError:
                pass
        print("### %s: %d lines" % (rel, len(lines)))
        stops = {}
        for label, argv in (("puc54ref", [str(ref)]),
                            ("luajit-joff", [str(luajit), "-joff"]),
                            ("luajit-jon", [str(luajit), "-jon"])):
            stops[label] = arm_runs(label, argv, lines, scratch, opts)
        print("\n=== stop points of %s ===" % rel)
        for label, st in stops.items():
            print("  %-12s %s" % (label, ", ".join("line %d" % ln for ln, _ in st)
                                  or "none (ran to the end)"))
            for ln, src in st:
                summary.append((rel, label, ln, src))
    print("\n=== table ===")
    print("| file:line | arm | the assert |")
    print("|---|---|---|")
    for rel, label, ln, src in summary:
        print("| %s:%d | %s | `%s` |" % (Path(rel).name, ln, label, src))
    return 0


if __name__ == "__main__":
    sys.exit(main())
