#!/usr/bin/env python3
"""Classic Lua benchmark comparison: stock LuaJIT 2.1 vs this fork vs PUC 5.4.9.

Measurement only; no source changes, no semantic fixes. Sources are pinned in
tests/bench/classic/manifest.txt and live in .dlcache/bench (offline boxes).
Each benchmark runs 3x per arm in one box job; median wall time is reported.
"""
import hashlib, json, os, shutil, subprocess, sys, tarfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BENCH = ROOT / ".dlcache" / "bench"
SRC = BENCH / "src"
MANIFEST = ROOT / "tests" / "bench" / "classic" / "manifest.txt"
STOCK = ROOT / "tmp" / "stock-luajit"
REF = ROOT / "tests" / "ref" / "bin" / "lua54ref"
OURS = ROOT / "src" / "luajit"
REPS = int(os.environ.get("BENCH_REPS", "3"))
STOCK_TAR = BENCH / "luajit-63c8f1a9.tar.gz"

# name: (script, argv, stdin, compare_stdout)
_ONLY = os.environ.get("BENCH_ONLY", "").strip()
BENCHES = {
    "nbody": ("n-body.lua", ["10000"], None, True),
    "spectral-norm": ("spectral-norm.lua", ["200"], None, True),
    "fannkuch-redux": ("fannkuch-redux.lua", ["9"], None, True),
    "binary-trees": ("binary-trees.lua", ["14"], None, True),
    "fasta": ("fasta.lua", ["10000"], None, True),
    "deltablue": ("deltablue-10000iterations.lua", ["locals"], None, True),
    "scimark": ("scimark.lua", ["-small"], None, False),
    "k-nucleotide": ("k-nucleotide.lua", [], "input.fasta", True),
    "regex-dna": ("regex-dna.lua", [], "input.fasta", True),
}
if _ONLY:
    BENCHES = {k: v for k, v in BENCHES.items() if k in _ONLY.split(",")}

def sha(path):
    h = hashlib.sha256(); h.update(path.read_bytes()); return h.hexdigest()

def check_pins():
    for line in MANIFEST.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            sys.exit("bad manifest line: " + line)
        file, _url, want = parts[0], parts[1], parts[2]
        p = BENCH / file
        if not p.exists() or sha(p) != want:
            sys.exit("missing/bad pin %s (run tests/bench/classic/fetch.sh on a networked host)" % p)

def extract_sources():
    if (SRC / "n-body.lua").exists() and (SRC / "deltablue" / "deltablue-10000iterations.lua").exists():
        return
    tmp = BENCH / "src.new"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    with tarfile.open(BENCH / "lua-benchmarks-gl-e1b3f24.tar.gz") as t:
        t.extractall(tmp, filter="data")
    (tmp / "deltablue").mkdir()
    with tarfile.open(BENCH / "deltablue-73f4a24.tar.gz") as t:
        t.extractall(tmp / "deltablue", filter="data")
    for p in tmp.iterdir():
        if p.is_dir() and p.name.endswith(".git"):
            pass
    # strip the archive's single top-level directory
    tops = [p for p in tmp.iterdir() if p.is_dir()]
    base = tops[0]
    for p in base.iterdir():
        shutil.move(str(p), str(tmp / p.name))
    shutil.rmtree(base)
    shutil.rmtree(SRC, ignore_errors=True)
    tmp.rename(SRC)
    # deltablue archive also has a top-level dir
    ddir = SRC / "deltablue"
    tops = [p for p in ddir.iterdir() if p.is_dir()]
    if tops:
        base = tops[0]
        for p in base.iterdir():
            shutil.move(str(p), str(ddir / p.name))
        shutil.rmtree(base)

def build_stock():
    if (STOCK / "src" / "luajit").is_file():
        return
    if STOCK.exists():
        shutil.rmtree(STOCK)
    STOCK.mkdir(parents=True)
    with tarfile.open(STOCK_TAR) as t:
        t.extractall(STOCK, filter="data")
    tops = [p for p in STOCK.iterdir() if p.is_dir()]
    base = tops[0]
    env = dict(os.environ)
    r = subprocess.run(["make", "-j" + str(os.cpu_count() or 4)], cwd=base, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode:
        sys.exit("stock LuaJIT build failed: " + r.stderr.decode()[-2000:])
    for p in base.iterdir():
        shutil.move(str(p), str(STOCK / p.name))
    base.rmdir()

def run_one(cmd, cwd, stdin_file, timeout=300):
    stdin = open(stdin_file, "rb") if stdin_file else subprocess.DEVNULL
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, cwd=cwd, stdin=stdin, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        if stdin_file: stdin.close()
        return None, b"", b"TIMEOUT"
    finally:
        if stdin_file: stdin.close()
    dt = (time.monotonic() - t0) * 1000.0
    return dt, p.stdout, p.stderr

def median(v):
    v = sorted(v)
    n = len(v)
    return v[n//2] if n % 2 else (v[n//2-1] + v[n//2]) / 2

def main():
    check_pins(); extract_sources(); build_stock()
    if not OURS.is_file() or not REF.is_file():
        sys.exit("need src/luajit and tests/ref/bin/lua54ref (build/fetch first)")
    stock = STOCK / "src" / "luajit"
    arms = [("stock", [str(stock), "-jon"]), ("ours", [str(OURS), "-jon"]),
            ("puc", [str(REF)])]
    rows = []
    for name, (script, argv, stdin_name, compare) in BENCHES.items():
        if name == "deltablue":
            cwd = SRC / "deltablue"
        else:
            cwd = SRC
        stdin_file = str(BENCH / stdin_name) if stdin_name else None
        data = {}
        for label, prefix in arms:
            vals, outs, errs = [], [], []
            for _ in range(REPS):
                dt, out, err = run_one(prefix + [script] + argv, cwd, stdin_file)
                if dt is None:
                    vals.append(None); outs.append(out); errs.append(err)
                else:
                    vals.append(dt); outs.append(out); errs.append(err)
            ok_vals = [v for v in vals if v is not None]
            med = median(ok_vals) if ok_vals else None
            data[label] = {"median_ms": med, "stdout": outs[0] if outs else b"",
                           "stderr": errs[-1] if errs else b"", "runs": vals}
        so, oo = data["stock"]["median_ms"], data["ours"]["median_ms"]
        po = data["puc"]["median_ms"]
        ratio = (so / oo) if (so and oo) else None
        ratio_puc = (po / oo) if (po and oo) else None
        diff = ""
        if compare and data["stock"]["stdout"] != data["ours"]["stdout"]:
            diff = "stock!=ours"
        if compare and data["puc"]["stdout"] != data["ours"]["stdout"]:
            diff = (diff + ",puc!=ours").strip(",")
        rows.append({"bench": name, "stock": so, "ours": oo, "puc": po,
                     "stock_ours_ratio": ratio, "puc_ours_ratio": ratio_puc,
                     "result_diff": diff})
        print("%-14s stock=%8s ours=%8s puc=%8s stock/ours=%6s puc/ours=%6s %s"
              % (name, fmt(so), fmt(oo), fmt(po), fmt(ratio), fmt(ratio_puc), diff), flush=True)
    print("\n| benchmark | stock ms | ours ms | PUC ms | stock/ours | PUC/ours | result |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for r in rows:
        print("| %s | %s | %s | %s | %s | %s | %s |" %
              (r["bench"], fmt(r["stock"]), fmt(r["ours"]), fmt(r["puc"]),
               fmt(r["stock_ours_ratio"]), fmt(r["puc_ours_ratio"]),
               r["result_diff"] or "-"))
    slow = [r for r in rows if r["stock_ours_ratio"] and r["stock_ours_ratio"] < 0.90]
    print("\nSLOWER than stock by >10%:", ", ".join(r["bench"] for r in slow) or "none")
    out = ROOT / "tests" / "report" / "bench-classic.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"reps": REPS, "rows": rows}, indent=2))
    return 0 if not slow else 0  # findings are report-only, never a gate failure

def fmt(v):
    return "-" if v is None else ("%.1f" % v)

if __name__ == "__main__":
    sys.exit(main())
