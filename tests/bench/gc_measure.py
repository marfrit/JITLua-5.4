#!/usr/bin/env python3
"""GC measurement runner for JITLua-5.4 (measurement only, no GC changes).

Runs the classic benchmarks and the real-program corpus-ext suites under a
fixed set of arms in one job, interleaved (A, B, C, ..., A, B, C, ...), and
reports per-arm wall time, peak RSS (per-child ru_maxrss), GC cycles and pause
statistics from an optional LUAJIT_GC_STATS build.  gc-measure.sh builds the
binaries and calls this script; see docs/gc-baseline-2026-11.md for the method.
"""
import hashlib
import io
import json
import os
import re
import signal
import statistics
import subprocess
import sys
import tarfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / ".dlcache" / "bench"
SRC = BENCH / "src"
STOCK = ROOT / "tmp" / "stock-luajit"
OURS = ROOT / "src" / "luajit"
REF = ROOT / "tests" / "ref" / "bin" / "lua54ref"
OURS_STATS = ROOT / "tmp" / "gcstats" / "src" / "luajit"
STOCK_STATS = ROOT / "tmp" / "stock-stats" / "src" / "luajit"
PUC_STATS = ROOT / "tmp" / "puc-stats" / "src" / "lua"
CORPUS = ROOT / "tmp" / "gc-corpus"

REPS_MAX = int(os.environ.get("GC_REPS_MAX", "5"))
ONLY = os.environ.get("GC_ONLY", "").strip()
DO_CLASSIC = os.environ.get("GC_CLASSIC", "1") != "0"
DO_CORPUS = os.environ.get("GC_CORPUS", "1") != "0"
DEFER = 'collectgarbage("setpause",1000)'
GEN = 'collectgarbage("generational")'

CLASSIC = {
    "nbody": ("n-body.lua", ["10000"], None),
    "spectral-norm": ("spectral-norm.lua", ["200"], None),
    "fannkuch-redux": ("fannkuch-redux.lua", ["9"], None),
    "binary-trees": ("binary-trees.lua", ["14"], None),
    "fasta": ("fasta.lua", ["10000"], None),
    "deltablue": ("deltablue-10000iterations.lua", ["locals"], None),
    "scimark": ("scimark.lua", ["-small"], None),
    "k-nucleotide": ("k-nucleotide.lua", [], "input.fasta"),
    "regex-dna": ("regex-dna.lua", [], "input.fasta"),
}

# Real programs from tests/corpus-ext.  Each workload is the library's own
# suite: every listed script runs once per repetition, in its own process; the
# repetition's wall time is the sum, peak RSS is the maximum over the children.
CORPUS_SPEC = {
    "luafilesystem": {
        "archive": "luafilesystem-1.8.0.tar.gz", "top": "luafilesystem-1_8_0",
        "cmod": ("lfs", "src/lfs.c", ""),
        "scripts": ["tests/test.lua"], "cwd": "", "lua_path": ";;",
    },
    "lpeg": {
        "archive": "lpeg-1.1.0.tar.gz", "top": "lpeg-1.1.0",
        "cmod": ("lpeg", "lptree.c lpvm.c lpcap.c lpcode.c lpprint.c lpcset.c",
                 "-std=c99 -DNDEBUG"),
        "scripts": ["test.lua"], "cwd": "", "lua_path": "./?.lua;;",
    },
    "lua-cjson": {
        "archive": "lua-cjson-2.1.0.14.tar.gz", "top": "lua-cjson-2.1.0.14",
        "cmod": ("cjson", "lua_cjson.c strbuf.c fpconv.c", "-DNDEBUG"),
        "scripts": ["test.lua"], "cwd": "tests",
        "lua_path": "../lua/?.lua;;",
    },
    "penlight": {
        "archive": "penlight-1.14.0.tar.gz", "top": "Penlight-1.14.0",
        "scripts": ["tests/test-*.lua"], "cwd": "",
        "lua_path": "./lua/?.lua;./lua/?/init.lua;;",
    },
    "serpent": {
        "archive": "serpent-0.30.tar.gz", "top": "serpent-0.30",
        "scripts": ["t/test.lua"], "cwd": "", "lua_path": "./src/?.lua;;",
    },
    "luaunit": {
        "archive": "luaunit-3.4.tar.gz", "top": "luaunit-LUAUNIT_V3_4",
        "scripts": ["run_unit_tests.lua"], "cwd": "", "lua_path": "./?.lua;;",
    },
    "rxi-json": {
        "archive": "rxi-json-0.1.2.tar.gz", "top": "json.lua-0.1.2",
        "scripts": ["test.lua"], "cwd": "test", "lua_path": "./?.lua;;",
    },
    "dkjson": {
        "archive": "dkjson-2.8-1.src.rock", "top": "dkjson-2.8",
        "scripts": ["jsontest.lua"], "cwd": "", "lua_path": "./?.lua;;",
    },
}


def arms():
    """Timing arms and stats arms.  A missing stats binary drops that arm."""
    t = [
        ("ours", "ours", [str(OURS), "-jon"]),
        ("ours-defer", "ours", [str(OURS), "-jon", "-e", DEFER]),
        ("ours-pause100", "ours", [str(OURS), "-jon", "-e",
                                   'collectgarbage("setpause",100)']),
        ("ours-gen", "ours", [str(OURS), "-jon", "-e", GEN]),
        ("stock", "stock", [str(STOCK / "src" / "luajit"), "-jon"]),
        ("stock-defer", "stock", [str(STOCK / "src" / "luajit"), "-jon", "-e", DEFER]),
        ("puc-inc", "puc", [str(REF)]),
        ("puc-gen", "puc", [str(REF), "-e", GEN]),
    ]
    s = []
    if OURS_STATS.is_file():
        s.append(("ours-stats", "ours", [str(OURS_STATS), "-jon"]))
    if STOCK_STATS.is_file():
        s.append(("stock-stats", "stock", [str(STOCK_STATS), "-jon"]))
    if PUC_STATS.is_file():
        s.append(("puc-stats-inc", "puc", [str(PUC_STATS)]))
        s.append(("puc-stats-gen", "puc", [str(PUC_STATS), "-e", GEN]))
    return t, s


# -- child execution with per-child rusage (os.wait4) ------------------------

def run_child(argv, cwd, stdin_path=None, env=None, timeout=600):
    """fork/exec one process; return wall_ms, ru_maxrss_kb, exit, stdout, stderr."""
    out = CORPUS / ".run.out"
    err = CORPUS / ".run.err"
    outf = open(out, "wb")
    errf = open(err, "wb")
    inf = open(stdin_path, "rb") if stdin_path else open(os.devnull, "rb")
    t0 = time.monotonic()
    pid = os.fork()
    if pid == 0:  # child
        try:
            os.chdir(cwd)
            os.dup2(inf.fileno(), 0)
            os.dup2(outf.fileno(), 1)
            os.dup2(errf.fileno(), 2)
            os.execvpe(argv[0], argv, env if env is not None else os.environ)
        except BaseException:
            os._exit(127)
    inf.close(); outf.close(); errf.close()
    status = None
    deadline = t0 + timeout
    while True:
        wpid, st, ru = os.wait4(pid, os.WNOHANG)
        if wpid == pid:
            status, rusage = st, ru
            break
        if time.monotonic() > deadline:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            _, status, rusage = os.wait4(pid, 0)
            break
        time.sleep(0.002)
    wall_ms = (time.monotonic() - t0) * 1000.0
    code = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status
    # Linux ru_maxrss is KB; normalise other platforms defensively.
    rss_kb = rusage.ru_maxrss if os.uname().sysname == "Linux" else rusage.ru_maxrss // 1024
    data = out.read_bytes()
    errdata = err.read_bytes()
    return {"wall_ms": wall_ms, "maxrss_kb": rss_kb, "exit": code,
            "stdout_sha": hashlib.sha1(data).hexdigest()[:12],
            "stdout_bytes": len(data), "stderr": errdata.decode("utf-8", "replace"),
            "stderr_tail": errdata[-2000:].decode("utf-8", "replace")}


GCSTATS_RE = re.compile(r"^GCSTATS (.*)$", re.M)


def parse_gcstats(stderr_text):
    m = GCSTATS_RE.search(stderr_text)
    if not m:
        return None
    d = {}
    for kv in m.group(1).split():
        k, _, v = kv.partition("=")
        try:
            d[k] = float(v) if "." in v else int(v)
        except ValueError:
            d[k] = v
    return d


def median(vals):
    return statistics.median(vals) if vals else None


# -- corpus-ext extraction and C modules ------------------------------------

def ensure_corpus(workloads):
    """Extract the pinned corpus-ext archives into tmp/gc-corpus."""
    CORPUS.mkdir(parents=True, exist_ok=True)
    for name, spec in workloads.items():
        d = CORPUS / name / spec["top"]
        if d.is_dir():
            continue
        arc = ROOT / ".dlcache" / spec["archive"]
        dst = CORPUS / name
        dst.mkdir(parents=True, exist_ok=True)
        if arc.suffix == ".rock":
            z = zipfile.ZipFile(arc)
            member = [m for m in z.namelist() if m.endswith(".tar.gz")][0]
            data = z.read(member)
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
                t.extractall(dst, filter="data")
        else:
            with tarfile.open(arc) as t:
                t.extractall(dst, filter="data")


def build_cmods(workloads):
    """Build the C modules once per header family: puc, ours, stock."""
    inc = {"puc": ROOT / "tests" / "ref" / "src" / "lua-5.4.9" / "src",
           "ours": ROOT / "src", "stock": STOCK / "src"}
    want = [f.strip() for f in os.environ.get("GC_MOD_FAMILIES", "puc,ours,stock").split(",") if f.strip()]
    inc = {k: v for k, v in inc.items() if k in want}
    cc = os.environ.get("CC", "cc")
    built = {"puc": {}, "ours": {}, "stock": {}}
    for name, spec in workloads.items():
        if "cmod" not in spec:
            continue
        soname, srcs, flags = spec["cmod"]
        base = CORPUS / name / spec["top"]
        for fam, hdir in inc.items():
            outdir = CORPUS / "mod" / fam
            outdir.mkdir(parents=True, exist_ok=True)
            so = outdir / (soname + ".so")
            if so.is_file():
                built[fam][name] = str(outdir)
                continue
            cmd = [cc, "-O2", "-shared", "-fPIC", "-I" + str(hdir), "-o", str(so)]
            if flags:
                cmd += flags.split()
            cmd += [str(base / s) for s in srcs.split()]
            r = subprocess.run(cmd, cwd=str(base), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
            if r.returncode:
                print("BUILD-FAIL %s %s: %s" % (name, fam,
                      r.stderr.decode("utf-8", "replace")[-300:]), flush=True)
            else:
                built[fam][name] = str(outdir)
    return built


def corpus_workloads(specs):
    out = []
    for name, spec in specs.items():
        base = CORPUS / name / spec["top"]
        scripts = []
        for pat in spec["scripts"]:
            if "*" in pat:
                scripts += sorted(str(p.relative_to(base))
                                  for p in (base / Path(pat).parent).glob(Path(pat).name))
            else:
                scripts.append(pat)
        if not base.is_dir() or not scripts:
            print("CORPUS-MISSING", name, flush=True)
            continue
        out.append({"name": name, "kind": "corpus", "base": base,
                    "cwd": base / spec.get("cwd", ""), "scripts": scripts,
                    "lua_path": spec["lua_path"], "needs_mod": name if "cmod" in spec else None})
    return out


def corpus_env(arm_family, base, wl, mods):
    env = dict(os.environ)
    env["LUA_PATH"] = wl["lua_path"].replace(";;", ";" + str(base / "?.lua") + ";" + str(base / "?/init.lua") + ";;")
    cpath = ";;"
    if wl["needs_mod"] and wl["needs_mod"] in mods.get(arm_family, {}):
        cpath = mods[arm_family][wl["needs_mod"]] + "/?.so;;"
    # lua-cjson and luafilesystem need lfs for penlight
    if arm_family in mods and "luafilesystem" in mods[arm_family]:
        cpath = mods[arm_family]["luafilesystem"] + "/?.so;" + cpath
    env["LUA_CPATH"] = cpath
    env.pop("LUA_INIT", None)
    return env


# -- workload execution ------------------------------------------------------

def run_repetition(wl, arm, mods, timeout):
    """Run one workload once with one arm; return aggregate measurements."""
    label, family, prefix = arm
    if wl["kind"] == "classic":
        script, argv, stdin_name = CLASSIC[wl["name"]]
        cwd = SRC / "deltablue" if wl["name"] == "deltablue" else SRC
        stdin_path = str(BENCH / stdin_name) if stdin_name else None
        r = run_child(prefix + [script] + argv, str(cwd), stdin_path, None, timeout)
        return r
    # corpus workload: several scripts, one process each
    env = corpus_env(family, wl["base"], wl, mods)
    prefix = list(prefix)
    # corpus-ext runs luaunit with jit.version=_VERSION so it takes its PUC
    # 5.4 branch; do the same for the LuaJIT-family arms.
    if wl["name"] == "luaunit" and family in ("ours", "stock"):
        prefix += ["-e", "jit.version=_VERSION"]
    total_ms, maxrss, fails, gc = 0.0, 0, 0, None
    shas = []
    errs = []
    for s in wl["scripts"]:
        r = run_child(prefix + [s], str(wl["cwd"]), None, env, timeout)
        total_ms += r["wall_ms"]
        maxrss = max(maxrss, r["maxrss_kb"])
        if r["exit"]:
            fails += 1
            if len(errs) < 3:
                errs.append("%s: %s" % (s, r["stderr"].strip()[:300]))
        shas.append(r["stdout_sha"])
        g = parse_gcstats(r["stderr_tail"])
        if g:
            if gc is None:
                gc = {k: 0 for k in g}
            for k, v in g.items():
                gc[k] += v
    return {"wall_ms": total_ms, "maxrss_kb": maxrss, "exit": 1 if fails else 0,
            "fails": fails, "stdout_sha": hashlib.sha1("".join(shas).encode()).hexdigest()[:12],
            "stderr_tail": "\n".join(errs), "gc": gc}


def reps_for(round1_ms):
    if round1_ms > 45000:
        return 1
    if round1_ms > 15000:
        return 2
    if round1_ms > 1500:
        return 3
    return REPS_MAX


def measure(wl, timing_arms, stats_arms, mods):
    print("\nWORK %s kind=%s" % (wl["name"], wl["kind"]), flush=True)
    reps = None
    runs = {a[0]: [] for a in timing_arms}
    stats = {}
    rep = 0
    while reps is None or rep < reps:
        round_ms = 0.0
        for arm in timing_arms:
            r = run_repetition(wl, arm, mods, 600)
            round_ms += r["wall_ms"]
            if r["exit"]:
                print("  FAIL %s rep %d exit=%s %s" %
                      (arm[0], rep, r["exit"], r["stderr_tail"].strip()[:160]), flush=True)
            runs[arm[0]].append(r)
        rep += 1
        if reps is None:
            reps = reps_for(round_ms)
            print("  reps=%d (round 1 total %.1f ms)" % (reps, round_ms), flush=True)
    for arm in stats_arms:
        r = run_repetition(wl, arm, mods, 1800)
        r["gc"] = r.get("gc") or parse_gcstats(r["stderr_tail"])
        stats[arm[0]] = r
        if r["exit"]:
            print("  FAIL %s exit=%s" % (arm[0], r["exit"]), flush=True)
    return runs, stats


def summarize(name, kind, runs, stats, timing_arms):
    rows = {}
    for arm in timing_arms:
        vals = [r["wall_ms"] for r in runs[arm[0]]]
        rss = [r["maxrss_kb"] for r in runs[arm[0]]]
        rows[arm[0]] = {"wall_ms": median(vals), "maxrss_kb": median(rss),
                        "n": len(vals), "fails": sum(1 for r in runs[arm[0]] if r["exit"]),
                        "raw_ms": vals, "raw_rss": rss}
    pause = {}
    for arm in stats:
        r = stats[arm]
        g = r.get("gc") or {}
        pause[arm] = {"cycles": g.get("cycles"), "steps": g.get("steps"),
                      "full": g.get("full"), "atomic": g.get("atomic"),
                      "step_p50_us": g.get("step_p50_us"), "step_p99_us": g.get("step_p99_us"),
                      "step_max_us": g.get("step_max_us"),
                      "atomic_p50_us": g.get("atomic_p50_us"),
                      "atomic_p99_us": g.get("atomic_p99_us"),
                      "atomic_max_us": g.get("atomic_max_us"),
                      "step_total_us": g.get("step_total_us"),
                      "step_total_ms": (g.get("step_total_us") or 0) / 1000.0,
                      "atomic_total_ms": (g.get("atomic_total_us") or 0) / 1000.0,
                      "maxrss_kb": r["maxrss_kb"], "wall_ms": r["wall_ms"]}
    return {"name": name, "kind": kind, "rows": rows, "pause": pause}


def print_workload(s):
    print("\n### %s (%s)" % (s["name"], s["kind"]))
    print("| arm | wall ms | peak RSS MB | reps |")
    print("|---|---:|---:|---:|")
    for a, r in s["rows"].items():
        w = r["wall_ms"]
        print("| %s | %s | %s | %s |" % (a, "-" if w is None else "%.1f" % w,
              "-" if r["maxrss_kb"] is None else "%.1f" % (r["maxrss_kb"] / 1024.0),
              ("%d (single)" % r["n"]) if r["n"] == 1 else str(r["n"])))
    for base, defer in (("ours", "ours-defer"), ("stock", "stock-defer"),
                        ("ours", "ours-pause100")):
        if base in s["rows"] and defer in s["rows"]:
            b = s["rows"][base]; d = s["rows"][defer]
            if b["wall_ms"] and d["wall_ms"]:
                print("GC %s->%s: default %.1f ms, changed %.1f ms, delta %.1f ms (%.1f%%) "
                      "| RSS %.1f -> %.1f MB (%+.1f%%)" %
                      (base, defer, b["wall_ms"], d["wall_ms"], b["wall_ms"] - d["wall_ms"],
                       100.0 * (b["wall_ms"] - d["wall_ms"]) / b["wall_ms"],
                       b["maxrss_kb"] / 1024.0, d["maxrss_kb"] / 1024.0,
                       100.0 * (d["maxrss_kb"] - b["maxrss_kb"]) / b["maxrss_kb"]))
    for a, p in s["pause"].items():
        print("PAUSE %s: cycles=%s steps=%s full=%s atomic=%s | step p50/p99/max %s/%s/%s us"
              " | atomic p50/p99/max %s/%s/%s us (p99 = histogram upper edge)"
              " | step total %s ms atomic total %s ms" %
              (a, p["cycles"], p["steps"], p["full"], p["atomic"],
               fmt(p["step_p50_us"]), fmt(p["step_p99_us"]), fmt(p["step_max_us"]),
               fmt(p["atomic_p50_us"]), fmt(p["atomic_p99_us"]), fmt(p["atomic_max_us"]),
               fmt(p["step_total_ms"], 1), fmt(p["atomic_total_ms"], 1)))


def fmt(v, dec=2):
    return "-" if v is None else ("%.*f" % (dec, v))


def main():
    CORPUS.mkdir(parents=True, exist_ok=True)
    for b in (OURS, REF, STOCK / "src" / "luajit"):
        if not Path(b).is_file():
            sys.exit("missing binary %s (gc-measure.sh builds it)" % b)
    timing_arms, stats_arms = arms()
    workloads = []
    if DO_CLASSIC:
        for name in CLASSIC:
            if ONLY and name not in ONLY.split(","):
                continue
            workloads.append({"name": name, "kind": "classic"})
    mods = {}
    if DO_CORPUS:
        selected = {k: v for k, v in CORPUS_SPEC.items()
                    if not ONLY or k in ONLY.split(",")}
        ensure_corpus(selected)
        mods = build_cmods(selected)
        for wl in corpus_workloads(selected):
            if ONLY and wl["name"] not in ONLY.split(","):
                continue
            workloads.append(wl)
    print("ARMS timing: %s" % ", ".join(a[0] for a in timing_arms))
    print("ARMS stats: %s" % (", ".join(a[0] for a in stats_arms) or "none"))
    summaries = []
    for wl in workloads:
        runs, stats = measure(wl, timing_arms, stats_arms, mods)
        s = summarize(wl["name"], wl["kind"], runs, stats, timing_arms)
        summaries.append(s)
        print_workload(s)
    print("\nSUMMARY " + json.dumps(summaries, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
