#!/usr/bin/env python3
"""JITLua-5.4 differential test runner (MISSION Phase 0).

Modes
  A  PUC-Lua 5.4.9 reference  vs  our LuaJIT with JIT off   (interpreter correctness)
  B  our LuaJIT JIT on        vs  our LuaJIT JIT off        (JIT correctness)
  R  our LuaJIT direct run    vs  string.dump -> load -> run (serializer round-trip)

A test passes when exit status, normalized stdout and normalized stderr agree.
A test whose `--! modes:` line excludes A has no reference arm and must also
end with status 0: two arms that fail the same assertion prove nothing.
Normalization is deliberately conservative (see canon/canon_err): whitespace,
absolute paths, heap addresses and the program-name prefix of error messages.
Number formatting, error wording and error line numbers are NOT normalized --
those differences are exactly what this port has to fix.

Expected failures are listed in tests/known-bad.tsv (real defects) and
tests/known-different.tsv (deliberate or implementation-defined differences),
both as test <TAB> modes <TAB> reason.
They are reported as XFAIL.  An entry that starts passing is reported as XPASS
so progress is visible; use --strict to make XPASS fatal.
Vendored puc54 files that mention the internal test library T are listed in
tests/t-guarded.tsv (test <TAB> run|skip <TAB> reason): "run" keeps the file in
the corpus with its T-guarded blocks dead in both arms, "skip" leaves it out.
"""

import argparse
import concurrent.futures
import difflib
import fnmatch
import json
import os
import re
import resource
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = ["tests/d54", "tests/corpus/puc54"]
KNOWN_BAD = ROOT / "tests" / "known-bad.tsv"
# Deliberate or implementation-defined differences from PUC 5.4.9 (not bugs).
# Same format and the same XFAIL handling as known-bad.tsv; kept apart so that
# known-bad.tsv lists only real defects.
KNOWN_DIFFERENT = ROOT / "tests" / "known-different.tsv"
# Vendored puc54 files that mention the internal test library T.  Neither arm
# has the PUC ltests hooks, so such a file used to be skipped whole.  Nine of
# the twelve guard every T use (`assert(not T or ...)`, `if T then ... end`,
# `if T == nil then ... return end`): with T undefined in both arms those blocks
# are dead code on both sides and the rest of the file is comparable.  Which
# files are of that kind is per-file knowledge, so it lives in a table:
# tests/t-guarded.tsv, `test<TAB>run|skip<TAB>reason`.  A file is only enabled
# once its own failures are classified (known-bad, known-different or an
# explicit skip row here), so the strict CI command never hides a file it has
# not classified.
T_GUARDED = ROOT / "tests" / "t-guarded.tsv"
REPORT_DIR = ROOT / "tests" / "report"
DUMP_RELOAD = ROOT / "tests" / "lib" / "dump_reload.lua"

ADDR_RE = re.compile(r"0x[0-9a-fA-F]{5,}")
PROG_RE = re.compile(r"(?m)^[^\n]*?/?(?:lua54ref|luajit|lua)(?:\.exe)?: ")
PATH_RE = re.compile(r"(?m)(?<![\w])/[^\s:]*/(?=[\w.\-]+\.lua:)")
# PUC internal test hooks (ltests.c / -DLUA_USER_H='"ltests.h"').  Neither arm
# can provide them; tests/t-guarded.tsv decides per file whether the file still
# runs with those blocks dead in both arms, or is skipped.
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

# The corpus C fixtures are built twice, once per arm (tests/ref/
# build-puc54-libs.sh): PUC-built modules are rejected by JITLua's
# luaL_checkversion now, so each arm loads only its own build.
CORPUS_LIBS = Path(os.environ.get("CORPUS_LIBS_OUT",
                                   ROOT / "tests" / "capi" / "build" / "corpus-libs"))


def arm_env(arm, scratch=None):
    """Environment for one arm.  The corpus C fixtures are installed in the
    test's private libs/ (install_libs), so the relative cpath resolves to
    that arm's build and no absolute build path leaks into test output."""
    env = dict(ENV)
    if scratch and (Path(scratch) / "libs").is_dir():
        cpath = "./libs/?.so;./?.so"
        env["LUA_CPATH"] = cpath
        env["LUA_CPATH_5_4"] = cpath
    return env

# Address-space limiting for the memory-heavy corpus files (puc54/heavy.lua).
# prlimit is preferred because a preexec_fn is unsafe with the job thread pool.
HAVE_PRLIMIT = shutil.which("prlimit") is not None


def parse_size(s):
    """'4G' -> 4294967296; a bare number is bytes."""
    s = str(s).strip().upper()
    mult = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
    if s and s[-1] in mult:
        return int(s[:-1]) * mult[s[-1]]
    return int(s)


def _as_limit(n):
    def _set():
        resource.setrlimit(resource.RLIMIT_AS, (n, n))
    return _set


def run(argv, cwd, timeout, mem_limit=None, env=None):
    """Run a child in its own process group; return (rc, out, err, timed_out).

    mem_limit caps RLIMIT_AS for both arms of puc54/heavy.lua: the reference
    and our binary then end in an allowed "not enough memory"/table-overflow
    error instead of OOM-killing the box.
    """
    preexec = None
    if mem_limit:
        if HAVE_PRLIMIT:
            argv = ["prlimit", "--as=%d" % mem_limit, "--"] + list(argv)
        else:
            preexec = _as_limit(mem_limit)
    try:
        p = subprocess.Popen(argv, cwd=str(cwd), env=env or ENV,
                             stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True,
                             preexec_fn=preexec)
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


def install_libs(scratch, arm):
    """Put the arm's C fixtures into <scratch>/libs (loadlib uses relative
    paths there), replacing any .so copied from the source tree.  A corpus
    without a libs/ directory needs no fixtures (returns True)."""
    libs = Path(scratch) / "libs"
    src = CORPUS_LIBS / arm
    if not libs.is_dir():
        return True
    if not src.is_dir():
        return False
    for old in libs.glob("*.so"):
        try:
            old.unlink()
        except OSError:
            pass
    for so in src.glob("*.so"):
        shutil.copy2(str(so), str(libs / so.name))
    return True


# Directives for vendored corpus files, which stay unmodified. A timeout here
# is an upper bound, the --timeout option still applies if it is lower.
VENDORED_DIRECTIVES = {
    # Ends in a loop that waits for a finalizer (see known-different.tsv); it
    # gets there in well under a second.
    "tests/corpus/puc54/db.lua": {"timeout": "10"},
}


def directives(path, text):
    d = {}
    for ln in text.split("\n")[:80]:
        m = re.match(r"\s*--!\s*([a-z_-]+)\s*:\s*(.*)$", ln)
        if m:
            d[m.group(1)] = m.group(2).strip()
    return d


def discover(corpus_dirs, filters, include_heavy=False):
    tests = []
    for c in corpus_dirs:
        base = ROOT / c
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.lua")):
            rel = p.relative_to(ROOT).as_posix()
            if "/libs/" in rel or "/packtests/" in rel:
                continue
            if rel.endswith("/puc54/heavy.lua") and not include_heavy:
                continue  # RLIMIT_AS-capped, explicit --include-heavy stage only.
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


def load_decisions(path):
    """test -> (decision, reason) from a `test<TAB>decision<TAB>reason` table."""
    d = {}
    if not path.exists():
        return d
    for ln in path.read_text().split("\n"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = ln.split("\t")
        if len(parts) < 2:
            continue
        d[parts[0]] = (parts[1].strip(), parts[2].strip() if len(parts) > 2 else "")
    return d


def known_reason(ctx, rel, mode):
    """Returns (reason, kind) for a job: kind is "bad" for a known defect,
    "different" for a known difference, "" if the job is in neither file.
    Looked up per test AND mode; a defect entry wins over a difference entry
    for the same job, so a defect is never reported as a mere difference."""
    reason = kb_reason(ctx["kb"], rel, mode)
    if reason is not None:
        return reason, "bad"
    reason = kb_reason(ctx.get("kd", {}), rel, mode)
    if reason is not None:
        return "KNOWN DIFFERENCE: " + reason, "different"
    return None, ""


def kb_reason(kb, rel, mode):
    ent = kb.get(rel)
    if not ent:
        return None
    letter = mode[0]
    for modes, reason in ent.items():
        if modes == "*" or letter in modes:
            return reason
    return None


# A sanitizer report or a death by signal is a failure on its own, whatever
# the other arm did: with the same instrumented binary in both arms of modes
# B and R, identical reports would otherwise compare equal and pass.
SANITIZER_RE = re.compile(r"ERROR: AddressSanitizer|AddressSanitizer:DEADLYSIGNAL|"
                          r"runtime error:|==\d+==ERROR|ERROR: LeakSanitizer")


def hard_failure(res, label):
    """res = (rc, out, err, timeout). Returns a detail string or None."""
    rc, _out, err, to = res
    m = SANITIZER_RE.search(err)
    if m:
        i = err.rfind("\n", 0, m.start()) + 1
        return "sanitizer report in %s: %s" % (label, err[i:i + 300].strip())
    if not to and rc < 0 and rc != -1:
        return "%s died: %s" % (label, "cannot execute" if rc == -2 else
                                "signal %d" % -rc)
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
        self.kind = ""  # "bad" / "different": which known-* file lists the job
        self.selfcheck = False  # no reference arm: must end with status 0
        self.secs = 0.0

    def run(self, ctx):
        t0 = time.time()
        o = self.opts
        cwd = self.path.parent
        scratch = None
        if "/corpus/" in self.rel:
            # Upstream suite files create temp files in cwd; give each test a
            # private scratch dir with symlinks to its sibling files so the
            # repo stays clean and dofile()/require() of neighbours still work.
            # Sibling directories are copied, not linked: tests such as
            # attrib.lua create and delete files inside libs/, and the A, B
            # and R jobs of one file run concurrently.
            import shutil
            scratch = tempfile.mkdtemp(prefix="lj54-")
            for sib in self.path.parent.iterdir():
                dst = os.path.join(scratch, sib.name)
                try:
                    if sib.is_dir() and not sib.is_symlink():
                        shutil.copytree(sib, dst, symlinks=True)
                    else:
                        os.symlink(sib, dst)
                except OSError:
                    pass
            cwd = Path(scratch)
        name = self.path.name
        jit = ctx["luajit"]
        ref = ctx["ref"]
        extra = self.args
        to = self.timeout
        # Both arms of the heavy file run under an address-space cap; the
        # resulting memory error is an allowed outcome (Lua manual 3.4.7).
        ml = o.heavy_mem_limit if self.rel.endswith("puc54/heavy.lua") else None
        if ctx.get("gc_stress"):
            # GC stress: the collector runs on every allocation (pause 0), in
            # every arm, so a value that is kept alive only by luck (a box
            # handed out while dead-white, a key stored without a barrier)
            # gets collected under the test.
            extra_pre = ["-e", 'collectgarbage("setpause", 0)']
        else:
            extra_pre = []
        if self.mode == "A":
            if scratch and not install_libs(scratch, "puc"):
                self.status = "FAIL"
                self.detail = ("missing puc corpus libs in %s "
                               "(run fetch-ref.sh)" % (CORPUS_LIBS / "puc"))
                return self
            a = run([ref] + extra_pre + [name] + extra, cwd, to, ml,
                    env=arm_env("puc", scratch))
            if scratch:
                install_libs(scratch, "jit")
            b = run([jit, "-joff"] + extra_pre + [name] + extra, cwd, to, ml,
                    env=arm_env("jit", scratch))
            mismatch, detail = compare(a, b, "puc54", "luajit-jitoff")
        elif self.mode.startswith("B"):
            if scratch:
                install_libs(scratch, "jit")
            on = [jit, "-jon"]
            if "@" in self.mode:
                on += ["-O" + self.mode.split("@", 1)[1]]
            if o.jit_args:
                on += shlex.split(o.jit_args)
            a = run(on + extra_pre + [name] + extra, cwd, to, ml,
                    env=arm_env("jit", scratch))
            b = run([jit, "-joff"] + extra_pre + [name] + extra, cwd, to, ml,
                    env=arm_env("jit", scratch))
            mismatch, detail = compare(a, b, "luajit-jiton", "luajit-jitoff")
        elif self.mode == "R":
            if scratch:
                install_libs(scratch, "jit")
            a = run([jit, "-joff"] + extra_pre + [name] + extra, cwd, to, ml,
                    env=arm_env("jit", scratch))
            b = run([jit, "-joff"] + extra_pre + [str(DUMP_RELOAD), name] + extra, cwd, to, ml,
                    env=arm_env("jit", scratch))
            mismatch, detail = compare(a, b, "direct", "dump-reload")
        else:
            raise ValueError(self.mode)
        # A test that excludes mode A has no reference arm. Two arms that fail
        # the same assertion agree with each other, so agreement alone proves
        # nothing there: such a test has to end with status 0.
        if (self.selfcheck and not mismatch and not detail and
                a[0] != 0 and b[0] != 0):
            mismatch = True
            detail = ("both arms exit %d and the test has no reference arm "
                      "(modes exclude A): %s" %
                      (a[0], (canon_err(a[2]).strip().split("\n") or [""])[0][:200]))
        self.secs = time.time() - t0
        if scratch:
            import shutil
            shutil.rmtree(scratch, ignore_errors=True)
        hard = hard_failure(a, "arm 1") or hard_failure(b, "arm 2")
        if hard:
            # Never XFAIL: known-bad entries cover semantic gaps, not crashes.
            self.status, self.detail = "FAIL", hard
            return self
        reason, self.kind = known_reason(ctx, self.rel, self.mode)
        if detail.startswith("TIMEOUT"):
            # Both arms hit the limit. A known-bad entry covers it (XFAIL);
            # otherwise it is a failure of the run.
            self.status = "XFAIL" if reason is not None else "TIMEOUT"
            self.detail, self.reason = detail, reason or ""
            return self
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
        if "/corpus/puc54/" in rel and T_HOOK_RE.search(text):
            # Only the T-guarded blocks need the internal test library: the
            # table decides per file whether the rest of it still runs.
            decision, why = ctx["t_guarded"].get(rel, ("skip", "not triaged yet"))
            if decision != "run":
                skipped.append((rel, "needs PUC internal ltests hooks (T.*), "
                                     "unavailable in LuaJIT -- " + (why or "no reason given")))
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
        allow = [m.split()[0].upper() for m in d["modes"].split(",") if m.split()] if "modes" in d else None
        timeout = float(d["timeout"]) if "timeout" in d else opts.timeout
        if rel in VENDORED_DIRECTIVES and "timeout" in VENDORED_DIRECTIVES[rel]:
            timeout = min(timeout, float(VENDORED_DIRECTIVES[rel]["timeout"]))
        extra = shlex.split(d["args"]) if "args" in d else []
        for m in modes:
            if allow and m[0] not in allow:
                continue
            j = Job(p, rel, m, extra, opts)
            j.timeout = timeout
            j.selfcheck = bool(allow) and "A" not in allow
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
    ap.add_argument("--known-different", default=str(KNOWN_DIFFERENT))
    ap.add_argument("--t-guarded", default=str(T_GUARDED),
                    help="table of vendored puc54 files that may run without the "
                         "PUC test library T (test<TAB>run|skip<TAB>reason)")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    ap.add_argument("--opt-levels", default=None,
                    help="comma list of JIT opt levels for mode B (e.g. 0,1,2,3)")
    ap.add_argument("--jit-args", default="",
                    help="extra arguments for the JIT-on arm of mode B, "
                         "e.g. '-Ohotexit=1'")
    ap.add_argument("--report-dir", default=str(REPORT_DIR))
    ap.add_argument("--update-known-bad", action="store_true",
                    help="rewrite known-bad.tsv from the failures of this run")
    ap.add_argument("--strict", action="store_true", help="treat XPASS as failure")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--gc-stress", action="store_true",
                    help="run every arm with collectgarbage('setpause', 0)")
    ap.add_argument("--include-heavy", action="store_true",
                    help="include puc54/heavy.lua; both arms run under --heavy-mem-limit. Run alone, not in the default corpus")
    ap.add_argument("--heavy-mem-limit", default="4G",
                    help="RLIMIT_AS for every puc54/heavy.lua arm (bytes or K/M/G/T suffix; default 4G)")
    ap.add_argument("--list", action="store_true")
    opts = ap.parse_args()
    opts.heavy_mem_limit = parse_size(opts.heavy_mem_limit)

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
    tests = discover(corpus, opts.filter, opts.include_heavy)
    if opts.list:
        for p in tests:
            print(p.relative_to(ROOT).as_posix())
        return 0
    if not tests:
        sys.exit("error: no tests found in %s" % ", ".join(corpus))

    kb = load_known_bad(Path(opts.known_bad))
    kd = load_known_bad(Path(opts.known_different))
    t_guarded = load_decisions(Path(opts.t_guarded))
    luac = str(Path(opts.luac)) if Path(opts.luac).exists() else None
    if luac is None:
        print("warning: %s missing -- corpus syntax pre-flight disabled" % opts.luac)
    ctx = {"luajit": str(luajit), "ref": str(ref), "kb": kb, "kd": kd, "luac": luac,
           "gc_stress": opts.gc_stress, "t_guarded": t_guarded}
    jobs, skipped, bad = plan(tests, modes, ctx, opts)

    results = list(bad)
    with concurrent.futures.ThreadPoolExecutor(max_workers=opts.jobs) as ex:
        futs = [ex.submit(lambda j=j: j.run(ctx)) for j in jobs]
        for f in concurrent.futures.as_completed(futs):
            r = f.result()
            results.append(r)
            if opts.verbose or r.status in ("FAIL", "XPASS", "BAD", "TIMEOUT"):
                print("%-5s %-3s %s" % (r.status, r.mode, r.rel), flush=True)
                if r.status in ("FAIL", "BAD", "TIMEOUT") and r.detail:
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
        if r.status in ("FAIL", "TIMEOUT"):
            md += ["### %s [%s]" % (r.rel, r.mode), "```", r.detail[:2000], "```", ""]
    md += ["", "## expected failures: known defects (known-bad.tsv)", ""]
    for r in results:
        if r.status == "XFAIL" and r.kind != "different":
            md.append("- %s [%s] %s" % (r.rel, r.mode, r.reason))
    md += ["", "## expected failures: known differences (known-different.tsv)", ""]
    for r in results:
        if r.status == "XFAIL" and r.kind == "different":
            md.append("- %s [%s] %s" % (r.rel, r.mode, r.reason))
    md += ["", "## now passing (remove the entry from the file named)", ""]
    for r in results:
        if r.status == "XPASS":
            md.append("- %s [%s] %s" % (r.rel, r.mode, "known-different.tsv"
                                        if r.kind == "different" else "known-bad.tsv"))
    md += ["", "## skipped", ""]
    for t, why in skipped:
        md.append("- %s: %s" % (t, why))
    (rd / "last.md").write_text("\n".join(md) + "\n")
    print("  report: %s" % (rd / "last.md"))

    if opts.update_known_bad:
        old = kb
        fails = {}
        for r in results:
            # A job covered by known-different.tsv stays there. Everything else
            # that fails is a defect, also when the same test has a
            # difference entry for another mode.
            if r.status in ("FAIL", "XFAIL") and r.kind != "different":
                fails.setdefault(r.rel, set()).add(r.mode[0])
        lines = ["# test<TAB>modes(A/B/R/*)<TAB>reason",
                 "# Generated by tests/harness.sh --update-known-bad; curate reasons by hand.",
                 "# Baseline: unported LuaJIT 2.1 (base commit 63c8f1a9) vs PUC-Lua 5.4.9.",
                 "# Real defects only. Deliberate and implementation-defined differences from",
                 "# PUC 5.4.9 are in tests/known-different.tsv."]
        for rel in sorted(fails):
            modes_s = "".join(sorted(fails[rel]))
            reason = ""
            for r in results:
                if r.rel == rel and r.reason and r.kind != "different":
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

    bad_n = (counts.get("FAIL", 0) + counts.get("BAD", 0) + counts.get("TIMEOUT", 0)
             + (counts.get("XPASS", 0) if opts.strict else 0))
    return 1 if bad_n else 0


if __name__ == "__main__":
    sys.exit(main())
