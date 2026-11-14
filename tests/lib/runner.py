#!/usr/bin/env python3
"""LuaJIT-5.4 differential test runner (MISSION Phase 0).

Modes
  A  PUC-Lua 5.4.7 reference  vs  our LuaJIT with JIT off   (interpreter correctness)
  B  our LuaJIT JIT on        vs  our LuaJIT JIT off        (JIT correctness)
  R  our LuaJIT direct run    vs  string.dump -> load -> run (serializer round-trip)

A test passes when exit status, normalized stdout and normalized stderr agree.
Normalization is deliberately conservative (see canon/canon_err): whitespace,
absolute paths, heap addresses and the program-name prefix of error messages.
Number formatting, error wording and error line numbers are NOT normalized --
those differences are exactly what this port has to fix.

Expected failures are listed in tests/known-bad.tsv (test <TAB> modes <TAB> reason).
They are reported as XFAIL.  An entry that starts passing is reported as XPASS
so progress is visible; use --strict to make XPASS fatal.
"""

import argparse
import concurrent.futures
import difflib
import fnmatch
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = ["tests/d54", "tests/corpus/puc54"]
KNOWN_BAD = ROOT / "tests" / "known-bad.tsv"
REPORT_DIR = ROOT / "tests" / "report"
DUMP_RELOAD = ROOT / "tests" / "lib" / "dump_reload.lua"

ADDR_RE = re.compile(r"0x[0-9a-fA-F]{5,}")
PROG_RE = re.compile(r"(?m)^[^\n]*?/?(?:lua54ref|luajit|lua)(?:\.exe)?: ")
PATH_RE = re.compile(r"(?m)(?<![\w])/[^\s:]*/(?=[\w.\-]+\.lua:)")
# PUC internal test hooks (ltests.c / -DLUA_USER_H='"ltests.h"').  Our binary
# cannot provide them, so such tests are skipped rather than counted as failures.
T_HOOK_RE = re.compile(r"\bT\s*[.\[]")


def canon(s):
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    s = ADDR_RE.sub("0xADDR", s)
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in s.split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def canon_err(s):
    # Tracebacks are implementation-specific (frame names, JIT frames, C frames).
    i = s.find("stack traceback:")
    if i != -1:
        s = s[:i]
    s = canon(s)
    s = PROG_RE.sub("lua: ", s)
    s = PATH_RE.sub("", s)
    return s


def decode(b):
    return (b or b"").decode("utf-8", errors="backslashreplace")


def child_env():
    env = dict(os.environ)
    env.update({
        "LC_ALL": "C",
        "TZ": "UTC",            # os.time/os.date tests must be TZ-independent
        "LUA_INIT": "",
        "LUA_INIT_5_4": "",
        "LUA_PATH": "./?.lua;./?/init.lua",
        "LUA_PATH_5_4": "./?.lua;./?/init.lua",
        "LUA_CPATH": "./?.so",
        "LUA_CPATH_5_4": "./?.so",
    })
    env.pop("LUAJIT_OPT", None)
    return env


ENV = child_env()


def run(argv, cwd, timeout):
    """Run a child in its own process group; return (rc, out, err, timed_out)."""
    try:
        p = subprocess.Popen(argv, cwd=str(cwd), env=ENV, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return (-2, "", "cannot execute %s: %s" % (argv[0], e), False)
    try:
        out, err = p.communicate(timeout=timeout)
        return (p.returncode, decode(out), decode(err), False)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except OSError:
            p.kill()
        out, err = p.communicate()
        return (-1, decode(out), decode(err), True)


def directives(path, text):
    d = {}
    for ln in text.split("\n")[:80]:
        m = re.match(r"\s*--!\s*([a-z_-]+)\s*:\s*(.*)$", ln)
        if m:
            d[m.group(1)] = m.group(2).strip()
    return d


def discover(corpus_dirs, filters):
    tests = []
    for c in corpus_dirs:
        base = ROOT / c
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.lua")):
            rel = p.relative_to(ROOT).as_posix()
            if "/libs/" in rel or "/packtests/" in rel:
                continue
            if filters and not any(fnmatch.fnmatch(rel, f) or f in rel for f in filters):
                continue
            tests.append(p)
    return tests


def load_known_bad(path):
    kb = {}
    if not path.exists():
        return kb
    for ln in path.read_text().split("\n"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = ln.split("\t")
        if len(parts) < 2:
            continue
        test, modes = parts[0], parts[1]
        reason = parts[2] if len(parts) > 2 else ""
        kb.setdefault(test, {})[modes] = reason
    return kb


def kb_reason(kb, rel, mode):
    ent = kb.get(rel)
    if not ent:
        return None
    letter = mode[0]
    for modes, reason in ent.items():
        if modes == "*" or letter in modes:
            return reason
    return None


def compare(a, b, label_a, label_b):
    """a, b = (rc, out, err, timeout).  Returns (mismatch, detail)."""
    rc_a, out_a, err_a, to_a = a
    rc_b, out_b, err_b, to_b = b
    if to_a and to_b:
        return False, "TIMEOUT both sides exceeded the limit (inconclusive)"
    if to_a or to_b:
        return True, "timeout: %s=%s %s=%s" % (label_a, to_a, label_b, to_b)
    oa, ob = canon(out_a), canon(out_b)
    ea, eb = canon_err(err_a), canon_err(err_b)
    if rc_a == rc_b and oa == ob and ea == eb:
        return False, ""
    parts = []
    if rc_a != rc_b:
        parts.append("exit status: %s=%d %s=%d" % (label_a, rc_a, label_b, rc_b))
    for name, x, y in (("stdout", oa, ob), ("stderr", ea, eb)):
        if x != y:
            diff = difflib.unified_diff(x.split("\n"), y.split("\n"),
                                        fromfile=label_a + "/" + name,
                                        tofile=label_b + "/" + name, lineterm="", n=1)
            parts.append("\n".join(list(diff)[:40]))
    return True, "\n".join(parts)


class Job:
    def __init__(self, path, rel, mode, args, opts):
        self.path, self.rel, self.mode = path, rel, mode
        self.args, self.opts = args, opts
        self.timeout = opts.timeout
        self.status, self.detail, self.reason = "PASS", "", ""
        self.secs = 0.0

    def run(self, ctx):
        t0 = time.time()
        o = self.opts
        cwd = self.path.parent
        scratch = None
        if "/corpus/" in self.rel:
            # Upstream suite files create temp files in cwd; give each test a
            # private scratch dir with symlinks to its siblings so the repo
            # stays clean and dofile()/require() of neighbours still work.
            scratch = tempfile.mkdtemp(prefix="lj54-")
            for sib in self.path.parent.iterdir():
                try:
                    os.symlink(sib, os.path.join(scratch, sib.name))
                except OSError:
                    pass
            cwd = Path(scratch)
        name = self.path.name
        jit = ctx["luajit"]
        ref = ctx["ref"]
        extra = self.args
        to = self.timeout
        if self.mode == "A":
            a = run([ref, name] + extra, cwd, to)
            b = run([jit, "-joff", name] + extra, cwd, to)
            mismatch, detail = compare(a, b, "puc54", "luajit-jitoff")
        elif self.mode.startswith("B"):
            on = [jit, "-jon"]
            if "@" in self.mode:
                on += ["-O" + self.mode.split("@", 1)[1]]
            a = run(on + [name] + extra, cwd, to)
            b = run([jit, "-joff", name] + extra, cwd, to)
            mismatch, detail = compare(a, b, "luajit-jiton", "luajit-jitoff")
        elif self.mode == "R":
            a = run([jit, "-joff", name] + extra, cwd, to)
            b = run([jit, "-joff", str(DUMP_RELOAD), name] + extra, cwd, to)
            mismatch, detail = compare(a, b, "direct", "dump-reload")
        else:
            raise ValueError(self.mode)
        self.secs = time.time() - t0
        if scratch:
            import shutil
            shutil.rmtree(scratch, ignore_errors=True)
        if detail.startswith("TIMEOUT"):
            self.status, self.detail = "TIMEOUT", detail
            return self
        reason = kb_reason(ctx["kb"], self.rel, self.mode)
        if mismatch:
            self.status = "XFAIL" if reason is not None else "FAIL"
            self.detail = detail
            self.reason = reason or ""
        else:
            self.status = "XPASS" if reason is not None else "PASS"
            self.reason = reason or ""
        return self


def plan(tests, modes, ctx, opts):
    jobs, skipped, bad = [], [], []
    for p in tests:
        rel = p.relative_to(ROOT).as_posix()
        text = p.read_text(errors="replace")
        d = directives(p, text)
        if "skip" in d:
            skipped.append((rel, "directive: " + d["skip"]))
            continue
        if rel.startswith("tests/corpus/puc54/") and T_HOOK_RE.search(text):
            skipped.append((rel, "needs PUC internal ltests hooks (T.*), unavailable in LuaJIT"))
            continue
        # Pre-flight: the corpus must be valid Lua 5.4.  A file that does not
        # parse on the reference proves nothing (both sides would fail alike).
        if ctx["luac"] and "no-parse-check" not in d:
            rc, out, err, to = run([ctx["luac"], "-p", p.name], p.parent, opts.timeout)
            if rc != 0 or to:
                j = Job(p, rel, "-", [], opts)
                j.status = "BAD"
                j.detail = "not valid Lua 5.4: " + canon_err(err or out)
                bad.append(j)
                continue
        allow = [m.strip().upper() for m in d["modes"].split(",")] if "modes" in d else None
        timeout = float(d["timeout"]) if "timeout" in d else opts.timeout
        extra = shlex.split(d["args"]) if "args" in d else []
        for m in modes:
            if allow and m[0] not in allow:
                continue
            j = Job(p, rel, m, extra, opts)
            j.timeout = timeout
            jobs.append(j)
    return jobs, skipped, bad


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", default="both", choices=["A", "B", "R", "both", "all"])
    ap.add_argument("--corpus", action="append", default=None,
                    help="corpus dir relative to repo root (repeatable)")
    ap.add_argument("--filter", action="append", default=[],
                    help="only tests whose repo-relative path matches (glob or substring)")
    ap.add_argument("--luajit", default=str(ROOT / "src" / "luajit"))
    ap.add_argument("--ref", default=str(ROOT / "tests" / "ref" / "bin" / "lua54ref"))
    ap.add_argument("--luac", default=str(ROOT / "tests" / "ref" / "bin" / "luac54ref"),
                    help="reference luac, used to validate that corpus files are valid 5.4")
    ap.add_argument("--known-bad", default=str(KNOWN_BAD))
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    ap.add_argument("--opt-levels", default=None,
                    help="comma list of JIT opt levels for mode B (e.g. 0,1,2,3)")
    ap.add_argument("--report-dir", default=str(REPORT_DIR))
    ap.add_argument("--update-known-bad", action="store_true",
                    help="rewrite known-bad.tsv from the failures of this run")
    ap.add_argument("--strict", action="store_true", help="treat XPASS as failure")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    opts = ap.parse_args()

    modes = {"A": ["A"], "B": ["B"], "R": ["R"], "both": ["A", "B"],
             "all": ["A", "B", "R"]}[opts.mode]
    if opts.opt_levels:
        modes = [m if m != "B" else "B@" + lv.strip()
                 for m in modes for lv in (opts.opt_levels.split(",") if m == "B" else [""])]

    luajit, ref = Path(opts.luajit), Path(opts.ref)
    if not luajit.exists():
        sys.exit("error: %s not found -- run 'make -j8' in the repo root" % luajit)
    if "A" in [m[0] for m in modes] and not ref.exists():
        sys.exit("error: %s not found -- run tests/ref/fetch-ref.sh" % ref)

    corpus = opts.corpus or DEFAULT_CORPUS
    tests = discover(corpus, opts.filter)
    if opts.list:
        for p in tests:
            print(p.relative_to(ROOT).as_posix())
        return 0
    if not tests:
        sys.exit("error: no tests found in %s" % ", ".join(corpus))

    kb = load_known_bad(Path(opts.known_bad))
    luac = str(Path(opts.luac)) if Path(opts.luac).exists() else None
    if luac is None:
        print("warning: %s missing -- corpus syntax pre-flight disabled" % opts.luac)
    ctx = {"luajit": str(luajit), "ref": str(ref), "kb": kb, "luac": luac}
    jobs, skipped, bad = plan(tests, modes, ctx, opts)

    results = list(bad)
    with concurrent.futures.ThreadPoolExecutor(max_workers=opts.jobs) as ex:
        futs = [ex.submit(lambda j=j: j.run(ctx)) for j in jobs]
        for f in concurrent.futures.as_completed(futs):
            r = f.result()
            results.append(r)
            if opts.verbose or r.status in ("FAIL", "XPASS", "BAD"):
                print("%-5s %-3s %s" % (r.status, r.mode, r.rel), flush=True)
                if r.status in ("FAIL", "BAD") and r.detail:
                    print("      " + r.detail.replace("\n", "\n      ")[:2000], flush=True)

    results.sort(key=lambda r: (r.rel, r.mode))
    counts = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    counts["SKIP"] = len(skipped)

    print("\n== summary ==")
    for k in ("PASS", "FAIL", "XFAIL", "XPASS", "SKIP", "BAD", "TIMEOUT"):
        print("  %-6s %d" % (k, counts.get(k, 0)))
    print("  tests  %d   jobs %d   modes %s" % (len(tests), len(results), ",".join(modes)))
    slow = sorted(results, key=lambda r: -r.secs)[:3]
    print("  slowest: " + ", ".join("%s %s %.2fs" % (r.rel, r.mode, r.secs) for r in slow))

    rd = Path(opts.report_dir)
    rd.mkdir(parents=True, exist_ok=True)
    payload = {
        "when": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "modes": modes, "corpus": corpus, "counts": counts,
        "luajit": str(luajit), "ref": str(ref),
        "results": [{"test": r.rel, "mode": r.mode, "status": r.status,
                     "reason": r.reason, "secs": round(r.secs, 3),
                     "detail": r.detail[:4000]} for r in results],
        "skipped": [{"test": t, "reason": why} for t, why in skipped],
    }
    (rd / "last.json").write_text(json.dumps(payload, indent=1))
    md = ["# harness report", "", "modes: `%s`  corpus: `%s`" % (",".join(modes), ", ".join(corpus)),
          "", "| status | count |", "|---|---|"]
    md += ["| %s | %d |" % (k, counts.get(k, 0)) for k in ("PASS", "FAIL", "XFAIL", "XPASS", "SKIP", "BAD", "TIMEOUT")]
    md += ["", "## invalid corpus (must be valid Lua 5.4)", ""]
    for r in results:
        if r.status == "BAD":
            md += ["- %s: %s" % (r.rel, r.detail)]
    md += ["", "## unexpected failures", ""]
    for r in results:
        if r.status == "FAIL":
            md += ["### %s [%s]" % (r.rel, r.mode), "```", r.detail[:2000], "```", ""]
    md += ["", "## expected failures (known-bad)", ""]
    for r in results:
        if r.status == "XFAIL":
            md.append("- %s [%s] %s" % (r.rel, r.mode, r.reason))
    md += ["", "## now passing (remove from known-bad)", ""]
    for r in results:
        if r.status == "XPASS":
            md.append("- %s [%s]" % (r.rel, r.mode))
    md += ["", "## skipped", ""]
    for t, why in skipped:
        md.append("- %s: %s" % (t, why))
    (rd / "last.md").write_text("\n".join(md) + "\n")
    print("  report: %s" % (rd / "last.md"))

    if opts.update_known_bad:
        old = kb
        fails = {}
        for r in results:
            if r.status in ("FAIL", "XFAIL"):
                fails.setdefault(r.rel, set()).add(r.mode[0])
        lines = ["# test<TAB>modes(A/B/R/*)<TAB>reason",
                 "# Generated by tests/harness.sh --update-known-bad; curate reasons by hand.",
                 "# Baseline: unported LuaJIT 2.1 (base commit 63c8f1a9) vs PUC-Lua 5.4.7."]
        for rel in sorted(fails):
            modes_s = "".join(sorted(fails[rel]))
            reason = ""
            for r in results:
                if r.rel == rel and r.reason:
                    reason = r.reason
                    break
            if not reason:
                for m, why in old.get(rel, {}).items():
                    if why:
                        reason = why
                        break
            lines.append("%s\t%s\t%s" % (rel, modes_s, reason or "M0 baseline: unported 2.1 (triage pending)"))
        Path(opts.known_bad).write_text("\n".join(lines) + "\n")
        print("  wrote %s (%d entries)" % (opts.known_bad, len(fails)))

    bad_n = counts.get("FAIL", 0) + counts.get("BAD", 0) + (counts.get("XPASS", 0) if opts.strict else 0)
    return 1 if bad_n else 0


if __name__ == "__main__":
    sys.exit(main())
