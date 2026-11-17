#!/usr/bin/env python3
"""Diagnosis helper for the classic benchmark regressions (measurement only).

Runs stock LuaJIT 2.1 and this fork with -jv and -jdump=+rsi on one benchmark,
prints the trace-abort/NYI reasons that ours has and stock does not, and a
compact comparison of the hottest loop trace (IR/mcode instruction counts,
SLOAD/CONV/guard/call counts).
"""
import os, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "bench" / "classic"))
import run as br  # reuse pinned-source/build-stock helpers

B = br.BENCH
SRC = br.SRC
STOCK = br.STOCK / "src" / "luajit"
OURS = ROOT / "src" / "luajit"
LUA_PATH = "src/?.lua;src/?/init.lua;;"

def cmd_for(name, arm):
    script, argv, stdin, _cmp = br.BENCHES[name]
    cwd = SRC / "deltablue" if name == "deltablue" else SRC
    stdin_path = str(B / stdin) if stdin else None
    base = [arm, "-jon"]
    return lua_path(arm), base + [script] + argv, cwd, stdin_path

def lua_path(binary):
    p = Path(binary).resolve()
    # binary lives at <root>/src/luajit or <root>/tmp/stock-luajit/src/luajit
    root = p.parent.parent
    return ";".join([str(root / "src" / "?.lua"), str(root / "src" / "?" / "init.lua"), ""])

def run(binary, name, extra, out, err):
    lp, args, cwd, stdin = cmd_for(name, binary)
    args = args[:2] + extra + args[2:]  # options before the script, not after it
    env = dict(os.environ); env["LUA_PATH"] = lp
    fin = open(stdin, "rb") if stdin else subprocess.DEVNULL
    t0 = time.monotonic()
    try:
        p = subprocess.run(args + extra, cwd=cwd, stdin=fin, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    finally:
        if stdin: fin.close()
    out.write_bytes(p.stdout); err.write_bytes(p.stderr)
    return p.returncode, time.monotonic() - t0

JIT_RE = re.compile(r"^(?:---- TRACE|NYI|.*blacklist|.*abort).*$", re.M)
NUM_RE = re.compile(r"\b\d+\b")
ADDR_RE = re.compile(r"0x[0-9a-fA-F]+")
PATH_RE = re.compile(r"(/[^\s:]*/)([^/\s:]+\.lua)")

def canon(s):
    s = ADDR_RE.sub("0xADDR", s)
    s = PATH_RE.sub(r"\2", s)
    return s

def reasons(path):
    counts = {}
    text = path.read_text(errors="replace")
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("NYI:"):
            key = canon(s)
            counts[key] = counts.get(key, 0) + 1
        elif "[TRACE" in s and "--" in s:
            # Keep the reason phrase and its source location, not the trace id
            # or the hotloop that triggered it.
            key = canon(s.split("--", 1)[1].strip())
            counts[key] = counts.get(key, 0) + 1
    return counts

def parse_dump(path):
    text = path.read_text(errors="replace")
    blocks = []
    cur = None; where = None
    for ln in text.splitlines():
        m = re.match(r"---- TRACE (\d+) (start|IR|mcode|stop)", ln)
        if m:
            n, kind = int(m.group(1)), m.group(2)
            if kind == "start":
                cur = {"n": n, "start": ln, "ir": [], "mcode": [], "stop": ""}
                blocks.append(cur); where = "start"
            elif cur and kind == "IR": where = "ir"
            elif cur and kind == "mcode": where = "mcode"
            elif cur and kind == "stop": cur["stop"] = ln; where = "stop"
            continue
        if cur and where == "ir": cur["ir"].append(ln)
        elif cur and where == "mcode": cur["mcode"].append(ln)
    loops = [b for b in blocks if "loop" in b["stop"]]
    # "Hottest" = the loop trace with the largest machine code, stable across
    # runs where trace numbering differs.
    b = max(loops, key=lambda x: len(x["mcode"])) if loops else (max(blocks, key=lambda x: len(x["mcode"])) if blocks else None)
    return blocks, b

def tok_counts(ir):
    keys = ["SLOAD", "CONV", "EQ", "ABC", "CALL", "FLOAD", "HLOAD", "ULOAD", "VLOAD",
            "ALOAD", "ASTORE", "HSTORE", "UREF", "XLOAD", "XSTORE"]
    c = {k: sum(1 for ln in ir if k in ln) for k in keys}
    c["guards"] = sum(1 for ln in ir if ">" in ln)
    c["calls"] = sum(1 for ln in ir if "CALL" in ln or "lj_" in ln)
    c["lj_meta"] = sum(1 for ln in ir if "lj_meta" in ln)
    c["lj_i64"] = sum(1 for ln in ir if "lj_i64" in ln)
    c["lj_tab"] = sum(1 for ln in ir if "lj_tab" in ln)
    return c

def main():
    names = sys.argv[1:] or ["deltablue", "spectral-norm", "k-nucleotide"]
    br.check_pins(); br.extract_sources(); br.build_stock()
    for name in names:
        print("###", name, flush=True)
        for label, binary in (("stock", STOCK), ("ours", OURS)):
            out = Path("/tmp/%s-%s.out" % (name, label))
            err = Path("/tmp/%s-%s.err" % (name, label))
            rc, secs = run(binary, name, ["-jv"], out, err)
            print("%-5s -jv rc=%d %.2fs" % (label, rc, secs), flush=True)
            rs = reasons(err)
            print(" reasons %d" % len(rs))
            for k, v in sorted(rs.items(), key=lambda kv: -kv[1])[:25]:
                print("REASON %5d  %s" % (v, k))
            outd = Path("/tmp/%s-%s.dump" % (name, label))
            errd = Path("/tmp/%s-%s.dumperr" % (name, label))
            rc, secs = run(binary, name, ["-jdump=+rsi"], outd, errd)
            blocks, hot = parse_dump(outd)
            print("%-5s dumpout=%d dumpstderr=%r" % (label, outd.stat().st_size, errd.read_text(errors="replace")[:200]))
            if not hot:
                print("%-5s dump rc=%d %.2fs no trace" % (label, rc, secs)); continue
            c = tok_counts(hot["ir"])
            print("%-5s dump rc=%d %.2fs traces=%d hot=%d stop=%s" %
                  (label, rc, secs, len(blocks), hot["n"], hot["stop"].strip()))
            print("  IR=%d mcode=%d guards=%d calls=%d SLOAD=%d CONV=%d EQ=%d ABC=%d "
                  "FLOAD=%d HLOAD=%d ALOAD=%d ASTORE=%d lj_meta=%d lj_i64=%d lj_tab=%d" %
                  (len(hot["ir"]), len(hot["mcode"]), c["guards"], c["calls"],
                   c["SLOAD"], c["CONV"], c["EQ"], c["ABC"], c["FLOAD"], c["HLOAD"],
                   c["ALOAD"], c["ASTORE"], c["lj_meta"], c["lj_i64"], c["lj_tab"]))
            print("  IR text:")
            for ln in hot["ir"][:80]: print("   " + ln)
    return 0

if __name__ == "__main__":
    sys.exit(main())
