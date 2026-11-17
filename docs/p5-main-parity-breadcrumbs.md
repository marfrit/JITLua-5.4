# P5 main.lua parity — breadcrumbs

## Current goal
Make tests/corpus/puc54/main.lua run in the harness and reach parity with PUC lua.c 5.4.9.

## Worktree
- Path: /home/mfritsche/src/LuaJIT-5.4-main-parity
- Branch: main-parity (origin/main)
- Current commit: 250bba7c0386532407e3421fddb64e64369a17f0
- Note: arm-box reads from repo's main branch (9f94bc8a), NOT the worktree branch.
  Changes in the worktree are NOT visible to arm-box/build-box.
  To test, must merge worktree→main first.

## Changes made (in worktree, committed to main-parity)

### 1. tests/ref/build-puc54-libs.sh (NEW)
Builds libs/*.so from PUC 5.4 headers (tests/ref/src/lua-5.4.9/src/).
Compiles lib1, lib11, lib2, lib21, lib2-v2 from C sources in tests/corpus/puc54/libs/.
Uses gcc/clang detection, -fPIC -shared flags.

### 2. tests/ref/fetch-ref.sh (MODIFIED)
Added sourcing of build-puc54-libs.sh after tarball extraction:
```
. "$HERE/build-puc54-libs.sh"
```
This ensures libs are built fresh per box after fetch-ref.sh extracts the PUC tarball.

### 3. src/luajit.c (MODIFIED)
- Added FLAGS_WARN (32) to collectargs
- Added case 'W' handling: notail(argv[i]); *flags |= FLAGS_WARN;
- Added lua_warning(L, "@on", 0) when FLAGS_WARN is set (after handle_luainit)
- Fixed dolibrary(): strip version suffix from modname (the module name passed to require),
  not just from gname. This matches PUC 5.4 library resolution for lib2-v2 → lib2.

## Known-bad status
tests/corpus/puc54/main.lua row still in known-bad.tsv.
Reason was: "P5: corpus lacks built libs/*.so fixtures (both stop there); with fixtures
PUC itself stops on the interactive prompt test in this harness; progname/argv/traceback naming differ"

The libs fixture issue is now addressed by build-puc54-libs.sh.
The row should be removed once the worktree is merged to main and gates pass.

## Blocked on
1. **arm-box/x64-box visibility**: The boxes read from repo's main branch, not the worktree.
   Cannot gate-test without merging worktree→main.
2. **TTY-dependent tests**: The interactive mode (-i) and Ctrl-C tests genuinely need a TTY.
   The harness runs in subprocesses with pipes, not a real TTY.
   These tests will fail on the harness regardless of implementation parity.
3. **Interpreter parity**: Remaining parity gaps after libs fix:
   - Interactive prompt mode (-i): needs real stdin TTY
   - Ctrl-C handling: needs real signal handling
   - progname/argv/traceback naming: LuaJIT uses "luajit" vs PUC "lua"
   - Error output format: may differ in traceback framing

## Next steps
1. Merge main-parity→main (git -C /home/mfritsche/src/LuaJIT-5.4-main-parity merge)
2. Run arm-box gate: export XDG_CACHE_HOME=$PWD/.dlcache; make clean >/dev/null; make -j8 >/dev/null && tests/ref/fetch-ref.sh --force >/dev/null && tests/harness.sh --mode A --timeout 180 --filter "tests/corpus/puc54/main.lua" --verbose
3. Run x64-box gate (parallel)
4. Update known-bad.tsv: remove main.lua row if gates pass
5. Document TTY-dependent sub-tests in docs/

## File paths
- tests/ref/build-puc54-libs.sh
- tests/ref/fetch-ref.sh
- src/luajit.c
- tests/corpus/puc54/main.lua
- tests/lib/runner.py
- tests/known-bad.tsv
- tests/ref/manifest.txt
- tests/ref/dist/lua-5.4.9.tar.gz (PUC 5.4.9 tarball)
- tests/ref/sanbuild/src/ (PUC source tree, created by fetch-ref.sh)
