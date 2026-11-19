#!/usr/bin/env python3
"""Perf diagnosis driver for the classic benchmarks (measurement only).

Builds stock LuaJIT 2.1 and this fork in one box job, interleaves the timing
arms, and prints compact summaries of -jv / -jdump / -jp runs. The raw dumps
stay on the box; only the derived numbers are printed. Nothing here changes
the benchmark sources or the VM.

Usage: perfdiag.py <phase> [bench...]
  jv       trace/abort/NYI/blacklist census
  dump     hot-trace IR/mcode/guards + taken-exit counts
  ir       print the hot trace IR of both arms (for a textual diff)
  prof     -jp=v and -jp=fl profiles
  time     interleaved wall times, several option sets
  all      jv + dump + prof + time
"""
import os, re, subprocess, sys, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "bench" / "classic"))
import run as br  # noqa: E402

STOCK = br.STOCK / "src" / "luajit"
OURS = ROOT / "src" / "luajit"
ARMS = (("stock", STOCK), ("ours", OURS))


def lua_path(binary):
    root = Path(binary).resolve().parent.parent
    return ";".join([str(root / "src" / "?.lua"),
                     str(root / "src" / "?" / "init.lua"), ""])


def run(binary, name, opts, timeout=1200):
    script, argv, stdin, _ = br.BENCHES[name]
    cwd = br.SRC / "deltablue" if name == "deltablue" else br.SRC
    fin = open(br.BENCH / stdin, "rb") if stdin else subprocess.DEVNULL
    env = dict(os.environ)
    env["LUA_PATH"] = lua_path(binary)
    t0 = time.monotonic()
    try:
        p = subprocess.run([str(binary)] + opts + [script] + argv, cwd=cwd,
                           stdin=fin, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=env, timeout=timeout)
    finally:
        if stdin:
            fin.close()
    return ((time.monotonic() - t0) * 1000, p.returncode,
            p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace"))


ADDR = re.compile(r"0x[0-9a-fA-F]+")
PATH = re.compile(r"(/[^\s:]*/)([^/\s:]+\.lua)")


def canon(s):
    return PATH.sub(r"\2", ADDR.sub("0xADDR", s))


def parse_dump(text):
    blocks, cur, where = [], None, None
    for ln in text.splitlines():
        m = re.match(r"---- TRACE (\d+) (start|IR|mcode|stop|exit)", ln)
        if m:
            n, kind = int(m.group(1)), m.group(2)
            if kind == "start":
                cur = {"n": n, "start": ln, "ir": [], "mcode": [], "stop": "",
                       "exits": []}
                blocks.append(cur)
                where = "start"
            elif cur and kind == "IR":
                where = "ir"
            elif cur and kind == "mcode":
                where = "mcode"
            elif cur and kind == "stop":
                cur["stop"] = ln
                where = "stop"
            elif cur and kind == "exit":
                cur["exits"].append(ln)
                where = "exit"
            continue
        if cur and where == "ir":
            cur["ir"].append(ln)
        elif cur and where == "mcode":
            cur["mcode"].append(ln)
    return blocks


def hot_trace(blocks):
    loops = [b for b in blocks if "loop" in b["stop"]]
    pool = loops or blocks
    return max(pool, key=lambda x: len(x["mcode"])) if pool else None


def tok_counts(ir):
    c = Counter()
    for ln in ir:
        for tok in ("SLOAD", "CONV", "EQ", "ABC", "CALL", "FLOAD", "HLOAD", "ALOAD",
                    "ASTORE", "HSTORE", "UREF", "NEWREF", "HREFK", "AREF", "HREF"):
            if tok in ln:
                c[tok] += 1
        if ">" in ln:
            c["guards"] += 1
        if "lj_" in ln:
            c["calls"] += 1
    return c


# LuaJIT pads the trace number to width 3 ("[TRACE   1 ...]"), so the separator
# must be \s+, not one space; a single space silently dropped every 1- and
# 2-digit trace and made the "started" column an undercount.
TRACE_RE = re.compile(r"^\[TRACE\s+(\d+|-+)\s*(?:\((\d+)/(\d+)\))?\s*([^\s\]]+)")


def phase_jv(names):
    for name in names:
        print("### jv %s" % name, flush=True)
        for label, binary in ARMS:
            d, rc, out, err = run(binary, name, ["-jon", "-jv"])
            reasons, nyis, black = Counter(), Counter(), Counter()
            started = aborted = 0
            badarg = mm = 0
            for ln in err.splitlines():
                s = ln.strip()
                m = TRACE_RE.match(s)
                if m:
                    if m.group(1) == "---":
                        aborted += 1
                    else:
                        started += 1
                    if " -- " in s:
                        reasons[canon(s.split(" -- ", 1)[1].rstrip("]"))] += 1
                elif s.startswith("NYI:"):
                    nyis[canon(s)] += 1
                if "blacklisted" in s:
                    black[canon(s.split(" -- ", 1)[-1].rstrip("]"))] += 1
                if "bad argument" in s:
                    badarg += 1
                if "missing metamethod" in s:
                    mm += 1
            print("%s %-6s rc=%d %.0fms started=%d aborted=%d nyi=%d black=%d badarg=%d missing_mm=%d"
                  % (name, label, rc, d, started, aborted, sum(nyis.values()),
                     sum(black.values()), badarg, mm))
            for k, v in reasons.most_common(14):
                print("   reason %5d  %s" % (v, k))
            for k, v in nyis.most_common(8):
                print("   NYI    %5d  %s" % (v, k))


def phase_dump(names):
    for name in names:
        print("### dump %s" % name, flush=True)
        for label, binary in ARMS:
            d, rc, out, err = run(binary, name, ["-jon", "-jdump=+rsx"])
            blocks = parse_dump(out)
            hot = hot_trace(blocks)
            exits = Counter()
            for b in blocks:
                for ln in b["exits"]:
                    m = re.search(r"exit (\d+)", ln)
                    if m:
                        exits[(b["n"], int(m.group(1)))] += 1
            print("%s %-6s rc=%d %.0fms traces=%d loops=%d taken_exits=%d"
                  % (name, label, rc, d, len(blocks),
                     sum(1 for b in blocks if "loop" in b["stop"]), sum(exits.values())))
            if hot:
                c = tok_counts(hot["ir"])
                print("   hot trace %d IR=%d mcode=%d guards=%d calls=%d %s"
                      % (hot["n"], len(hot["ir"]), len(hot["mcode"]), c["guards"],
                         c["calls"], " ".join("%s=%d" % (k, c[k]) for k in
                         ("SLOAD", "CONV", "EQ", "FLOAD", "HLOAD", "ALOAD", "ASTORE",
                          "HSTORE", "NEWREF", "HREFK") if c[k])))
            for (tn, en), v in exits.most_common(10):
                print("   exit trace %d exit %d taken %d" % (tn, en, v))


def phase_ir(names):
    for name in names:
        print("### ir %s" % name, flush=True)
        texts = {}
        for label, binary in ARMS:
            d, rc, out, err = run(binary, name, ["-jon", "-jdump=+rsi"])
            blocks = parse_dump(out)
            loops = [b for b in blocks if "loop" in b["stop"]]
            loops.sort(key=lambda b: -len(b["mcode"]))
            print("==== %s loop traces by mcode ====" % label)
            for b in loops[:6]:
                c = tok_counts(b["ir"])
                print("   trace %d mcode=%d IR=%d guards=%d %s" %
                      (b["n"], len(b["mcode"]), len(b["ir"]), c["guards"],
                       " ".join("%s=%d" % (k, c[k]) for k in
                                ("SLOAD", "CONV", "EQ", "FLOAD", "HLOAD", "HREFK")
                                if c[k])))
            hot = hot_trace(blocks)
            texts[label] = hot["ir"] if hot else []
            print("==== %s hot trace %s (IR=%d) ====" % (label, hot["n"] if hot else "-",
                                                          len(texts[label])))
            for ln in texts[label]:
                print(ln)
        if texts["stock"] and texts["ours"]:
            print("==== IR token multiset diff (ours-stock) ====")
            a, b = Counter(tok_counts(texts["stock"]).items()), Counter(tok_counts(texts["ours"]).items())
            keys = sorted(set(a) | set(b))
            for k in keys:
                if a[k] != b[k]:
                    print("   %-8s stock=%d ours=%d" % (k, a[k], b[k]))


def phase_prof(names):
    for name in names:
        print("### prof %s" % name, flush=True)
        for label, binary in ARMS:
            d, rc, out, err = run(binary, name, ["-jon", "-jp=v"])
            print("%s %-6s -jp=v rc=%d %.0fms" % (name, label, rc, d))
            for ln in (out + err).splitlines():
                if "%" in ln:
                    print("   " + ln.strip())
        for label, binary in ARMS:
            d, rc, out, err = run(binary, name, ["-jon", "-jp=fl"])
            print("%s %-6s -jp=fl rc=%d %.0fms" % (name, label, rc, d))
            for ln in out.splitlines()[:16]:
                print("   " + ln.rstrip())


def phase_time(names):
    for name in names:
        print("### time %s" % name, flush=True)
        for opts, reps in ((["-jon"], 7), (["-joff"], 5),
                           (["-jon", "-Ohotexit=5,tryside=8"], 5),
                           (["-jon", "-Ohotloop=20"], 5),
                           (["-jon", "-Ohotexit=3,tryside=6"], 5)):
            ts, to = [], []
            for _ in range(reps):
                d, _, _, _ = run(STOCK, name, opts)
                ts.append(d)
                d, _, _, _ = run(OURS, name, opts)
                to.append(d)
            ts.sort()
            to.sort()
            sm, om = ts[len(ts) // 2], to[len(to) // 2]
            print("%s %-32s stock min=%8.1f med=%8.1f | ours min=%8.1f med=%8.1f"
                  " | ratio_min=%.3f ratio_med=%.3f"
                  % (name, " ".join(opts), ts[0], sm, to[0], om,
                     ts[0] / to[0], sm / om))


def phase_mcode(names):
    """mcode census: per-run trace count, instruction count, biggest loop trace."""
    for name in names:
        for arm, exe in ARMS:
            rows = []
            for _ in range(7):
                _ms, _rc, out, _err = run(exe, name, ["-jdump=+m"])
                cur = None
                traces = []
                for ln in out.splitlines():
                    if ln.startswith("---- TRACE") and " mcode " in ln:
                        cur = {"n": int(ln.split()[2]), "ins": 0, "size": 0}
                        traces.append(cur)
                    elif cur is not None and ln.startswith("---- TRACE"):
                        cur = None
                    elif cur is not None and ln and not ln.startswith("->"):
                        cur["ins"] += 1
                total = sum(t["ins"] for t in traces)
                big = max(traces, key=lambda t: t["ins"]) if traces else {"ins": 0}
                rows.append((len(traces), total, big["ins"]))
            print("%s %-6s runs(traces,total_ins,max_ins) = %s" %
                  (name, arm, " ".join("%d/%d/%d" % r for r in rows)))


def phase_census(names):
    """Per-benchmark -jv census: traces, aborts, and the two campaign notes."""
    print("bench\tarm\ttraces\taborts\tbadarg\tweak\tnomm\tnyi\tlines")
    for name in names:
        for arm, exe in ARMS:
            _ms, _rc, _out, err = run(exe, name, ["-jv"])
            low = err.lower()
            print("%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d" %
                  (name, arm, err.count("[TRACE"), err.count("[TRACE ---"),
                   low.count("bad argument"), low.count("weak"),
                   low.count("missing metamethod"), low.count("nyi"),
                   len(err.splitlines())))


def _bench_cwd(name):
    return br.SRC / "deltablue" if name == "deltablue" else br.SRC


def _run_bench(binary, name, opts, timeout=1200, with_argv=True):
    """Run a benchmark with LUA_PATH pointing at its own tree (jit.* modules)."""
    script, argv, stdin, _cmp = br.BENCHES[name]
    fin = open(br.BENCH / stdin, "rb") if stdin else subprocess.DEVNULL
    env = dict(os.environ)
    env["LUA_PATH"] = lua_path(binary)
    try:
        p = subprocess.run([str(binary)] + opts + [script] + (argv if with_argv else []),
                           cwd=_bench_cwd(name), stdin=fin,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env, timeout=timeout)
    finally:
        if stdin:
            fin.close()
    return p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")


START_RE = re.compile(r"^---- TRACE (\d+) start (.+?)(?:\s+--.*)?$")


def phase_starts(names):
    """Where do traces start? A trace-selection census from -jdump=+rs."""
    for name in names:
        print("### starts %s" % name, flush=True)
        for arm, exe in ARMS:
            out, err = _run_bench(exe, name, ["-jon", "-jdump=+rs"])
            starts = Counter()
            for ln in out.splitlines():
                m = START_RE.match(ln)
                if m:
                    starts[PATH.sub(r"\2", ADDR.sub("0xADDR", m.group(2)))] += 1
            print("%s %-6s trace starts=%d distinct=%d" %
                  (name, arm, sum(starts.values()), len(starts)))
            for src, n in starts.most_common(12):
                print("   %4d  %s" % (n, src))


def phase_bc(names):
    """Bytecode listing of the benchmark, both arms, diffed."""
    import difflib
    for name in names:
        print("### bc %s" % name, flush=True)
        texts = {}
        for arm, exe in ARMS:
            out, err = _run_bench(exe, name, ["-bl"], with_argv=False)
            if not out.strip():
                print("%s %-6s -bl produced no stdout; stderr: %s" %
                      (name, arm, err.strip()[:200]))
            texts[arm] = [PATH.sub(r"\2", ADDR.sub("0xADDR", ln)).rstrip()
                          for ln in out.splitlines()]
        diff = list(difflib.unified_diff(texts["stock"], texts["ours"],
                                         "stock", "ours", n=1, lineterm=""))
        print("%s bytecode lines: stock=%d ours=%d, diff lines=%d" %
              (name, len(texts["stock"]), len(texts["ours"]), len(diff)))
        for ln in diff[:150]:
            print(ln)


def phase_overhead(names):
    """Constant process cost: empty script, repeated; -jon and -joff."""
    print("### overhead", flush=True)
    for opts in (["-jon"], ["-joff"]):
        for arm, exe in ARMS:
            ts = []
            for _ in range(15):
                t0 = time.monotonic()
                subprocess.run([str(exe)] + opts + ["-e", ""],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
                ts.append((time.monotonic() - t0) * 1000)
            ts.sort()
            print("empty %-6s %-6s min=%.2fms median=%.2fms" %
                  (" ".join(opts), arm, ts[0], ts[len(ts) // 2]))


def phase_i64(names):
    """Box census: does the workload touch 5.4 integers/boxes at all?"""
    for name in names:
        print("### i64 %s" % name, flush=True)
        for arm, exe in ARMS:
            out, err = _run_bench(exe, name, ["-jon", "-jdump=+r"])
            toks = Counter()
            for ln in out.splitlines():
                for t in ("i64", "u64", "int64", "CONV", "TOBIT"):
                    if t in ln:
                        toks[t] += 1
            print("%s %-6s i64-ops=%d %s" %
                  (name, arm, toks["i64"],
                   " ".join("%s=%d" % (k, toks[k]) for k in
                            ("i64", "u64", "int64", "CONV", "TOBIT") if toks[k])))


def _run_cmd(binary, name, opts, stdin_path=None, extra=None):
    """Run an arbitrary command line in the benchmark cwd; returns (ms, out, err)."""
    script, argv, _stdin, _cmp = br.BENCHES[name]
    fin = None
    if stdin_path or _stdin:
        fin = open(stdin_path or (br.BENCH / _stdin), "rb")
    env = dict(os.environ)
    env["LUA_PATH"] = lua_path(binary)
    cmd = [str(binary)] + opts + ([extra] if extra else [script] + argv)
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, cwd=_bench_cwd(name),
                           stdin=fin if fin else subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    finally:
        if fin:
            fin.close()
    return ((time.monotonic() - t0) * 1000, p.stdout.decode(errors="replace"),
            p.stderr.decode(errors="replace"))


def phase_teardown(names):
    """Normal exit (lua_close) vs os.exit(0,false): isolates teardown cost."""
    print("### teardown", flush=True)
    for name in names:
        script, argv, _stdin, _cmp = br.BENCHES[name]
        varargs = ",".join('"%s"' % a for a in argv)
        wrapper = ('local f=assert(loadfile("%s")); f(%s); os.exit(0,false)'
                   % (script, varargs))
        for arm, exe in ARMS:
            close = sorted(_run_cmd(exe, name, ["-jon"])[0] for _ in range(7))
            noc = sorted(_run_cmd(exe, name, ["-jon", "-e"], extra=wrapper)[0]
                         for _ in range(7))
            print("%-13s %-6s close_med=%8.1f  exit_med=%8.1f  close-exit=%6.1f ms"
                  % (name, arm, close[3], noc[3], close[3] - noc[3]))


def phase_emptyinput(names):
    """Same workload on an empty stdin: process + IO + setup cost only."""
    empty = "/tmp/perfdiag-empty.fasta"
    open(empty, "wb").close()
    print("### emptyinput", flush=True)
    for name in names:
        if name != "k-nucleotide":
            continue
        for arm, exe in ARMS:
            t = sorted(_run_cmd(exe, name, ["-jon"], stdin_path=empty)[0]
                       for _ in range(9))
            print("%-13s %-6s empty_stdin_med=%7.2f ms  min=%7.2f"
                  % (name, arm, t[4], t[0]))


def _timeit(binary, code, opts=("-jon",), reps=7, cwd=None):
    """Median wall time of `binary opts -e code` in ms."""
    out = []
    for _ in range(reps):
        t0 = time.monotonic()
        subprocess.run([str(binary)] + list(opts) + ["-e", code],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       cwd=cwd)
        out.append((time.monotonic() - t0) * 1000)
    return sorted(out)[len(out) // 2]


def phase_gcmicro(names):
    """Is the close/free path per-object slow? Allocation micro, both arms."""
    N = 1000000
    alloc = ("local t={} for i=1,%d do t[i]={a=i,b=i+1} end" % N)
    cases = [
        ("tables+close", alloc),
        ("tables+exit", alloc + " os.exit(0,false)"),
        ("tables+exit+close", alloc + " os.exit(0,true)"),
        ("tables+gcstop+close", "collectgarbage('stop') " + alloc),
        ("tables+gcstop+exit", "collectgarbage('stop') " + alloc + " os.exit(0,false)"),
        ("strings+close", "local t={} for i=1,%d do t[i]='k'..i end" % N),
        ("strings+exit", "local t={} for i=1,%d do t[i]='k'..i end os.exit(0,false)" % N),
    ]
    print("### gcmicro (%d objects)" % N, flush=True)
    for label, code in cases:
        row = []
        for arm, exe in ARMS:
            row.append("%s=%.0f" % (arm, _timeit(exe, code)))
        print("  %-22s %s" % (label, "  ".join(row)))



def phase_gcrun(names):
    """Teardown under different GC policies: does close cost track the heap?"""
    print("### gcrun", flush=True)
    for name in names:
        script, argv, _stdin, _cmp = br.BENCHES[name]
        va = ",".join("'%s'" % a for a in argv)
        load = "local f=assert(loadfile('%s')) f(%s)" % (script, va)
        cases = [
            ("plain close", load),
            ("plain exit", load + " os.exit(0,false)"),
            ("gcstop close", "collectgarbage('stop') " + load),
            ("gcstop exit", "collectgarbage('stop') " + load + " os.exit(0,false)"),
            ("setpause100 close", "collectgarbage('setpause',100) " + load),
            ("setpause1000 close", "collectgarbage('setpause',1000) " + load),
        ]
        for label, code in cases:
            row = []
            for arm, exe in ARMS:
                row.append("%s=%.0f" % (arm, _timeit(exe, code, reps=3, cwd=_bench_cwd(name))))
            print("  %-18s %s" % (label, "  ".join(row)))



def phase_gcfull(names):
    """Cost of a full collection on the workload heap, in-script."""
    print("### gcfull", flush=True)
    for name in names:
        script, argv, _stdin, _cmp = br.BENCHES[name]
        va = ",".join("'%s'" % a for a in argv)
        wrapper = ("local f=assert(loadfile('" + script + "')) f(" + va + ") "
                   "local t=os.clock() for i=1,3 do collectgarbage('collect') end "
                   "io.stderr:write(string.format('GCFULL %.1f %.1f kB\\n', "
                   "(os.clock()-t)*1000, collectgarbage('count'))) "
                   "os.exit(0,false)")
        for arm, exe in ARMS:
            ms, _out, err = _run_cmd(exe, name, ["-jon", "-e"], extra=wrapper)
            line = [l for l in err.splitlines() if l.startswith("GCFULL")]
            print("  %-6s wall=%8.1f ms  %s" % (arm, ms, line[0] if line else err[-200:]))


PROBE_RE = re.compile(r"PROBE readseq=(\S+) freq1=(\S+) freq2=(\S+) c3=(\S+) c4=(\S+) "
                     r"c6=(\S+) c12=(\S+) c18=(\S+) work=(\S+) total=(\S+)")


def phase_knuc(names):
    """Stage-timed k-nucleotide probe: where does the whole-process time go?"""
    probe = str(ROOT / "tests" / "bench" / "knuc-probe.lua")
    stages = ("readseq", "freq1", "freq2", "c3", "c4", "c6", "c12", "c18",
              "work", "total")
    print("### knuc-probe", flush=True)
    for arm, exe in ARMS:
        rows = {s: [] for s in stages}
        wall = []
        for _ in range(9):
            ms, out, err = _run_cmd(exe, "k-nucleotide", ["-jon"], extra=probe)
            m = PROBE_RE.search(err)
            if not m:
                print("   %s: no PROBE line; stderr=%r" % (arm, err[:200]))
                break
            for i, s in enumerate(stages):
                rows[s].append(float(m.group(i + 1)))
            wall.append(ms)
        else:
            print("%-6s " % arm + "  ".join(
                "%s=%.2f" % (s, sorted(rows[s])[4]) for s in stages))
            print("%-6s wall_med=%.2f ms" % (arm, sorted(wall)[4]))


PHASES = {"jv": phase_jv, "dump": phase_dump, "ir": phase_ir, "prof": phase_prof,
          "time": phase_time, "census": phase_census, "mcode": phase_mcode,
          "starts": phase_starts, "bc": phase_bc, "overhead": phase_overhead,
          "i64": phase_i64, "teardown": phase_teardown,
          "emptyinput": phase_emptyinput, "knuc": phase_knuc,
          "gcmicro": phase_gcmicro, "gcrun": phase_gcrun,
          "gcfull": phase_gcfull}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in list(PHASES) + ["all"]:
        sys.exit(__doc__)
    phase = sys.argv[1]
    names = sys.argv[2:] or ["deltablue", "k-nucleotide"]
    br.check_pins()
    br.extract_sources()
    br.build_stock()
    if not OURS.is_file():
        sys.exit("build src/luajit first")
    todo = ["jv", "dump", "prof", "time"] if phase == "all" else [phase]
    for ph in todo:
        PHASES[ph](names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
