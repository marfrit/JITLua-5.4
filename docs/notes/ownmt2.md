# ownmt2: per-table weakness flag — implemented, measured, NOT landed (2026-11-19)

Branch `ownmt2` from main `f51a7608` (integ6 + the final-review fixes, merged).
Goal: replace the metatable-identity weakness guard with an exact per-table
`GCtab.weak` flag, so the own-mt idiom (one metatable per object, all weak or
all strong) keeps a single trace instead of exiting on every metatable.

## What was implemented (commit "jit: per-table weakness flag (experimental)",
reverted in the next commit)

- `GCtab.weak` (uint8_t, uses the 2 bytes of padding after `colo` — GCtab
  stays 64 bytes on GC64), `IRFL_TAB_WEAK`. Bits: 1 = `__mode` has 'k',
  2 = 'v', 0 = strong, `0xff` = stale (recompute). Initialised to 0 in
  `newtab`; copied in `lj_tab_dup`; cleared in `lj_tab_clear`.
- Exact maintenance at every string-key store:
  - `lj_tab_setstr` and `lj_tab_newkey` (C choke points; `lj_tab_set`'s
    string branch goes through `lj_tab_setstr`),
  - `meta_tset`'s existing-key path (`lua_setfield`/`lua_settable` bypass
    `lj_tab_set` there),
  - the VM `BC_TSETS_Z` fast path on x64 and arm64: the key pointer is
    compared against `gcroot[GCROOT_MMNAME+MM_mode]` before the hash walk
    (so no register is clobbered on the new-key path) and `tab.weak` is set
    to 0xff on a match.
- `rec_tabguard` recomputes the exact value from `__mode` at record time,
  writes it into the metatable, and emits `NE meta, NULL` +
  `FLOAD meta.weak` + `EQ weak, w` instead of `EQ meta, {mt}` plus the
  runtime `__mode` HREF guard. A weak value still marks `J->cur.weak` and
  the root trace weak.
- To make the flag useful, `lj_record_mm_lookup` must drop the identity guard
  and follow the runtime metatable structurally (otherwise the identity guard
  still exits per metatable). That is the part that regresses.

## Measurement (x64, interleaved `base f51a7608` vs this branch, median of 7)

method_call, N=20M (x64) / N=5M (arm64), same result on both arrows:
plain/field/fixed unchanged; **rotating 151.1 -> 305.0 ms (+102%) on x64,
7.4 -> 14.9 ms (+101%) on arm64**; **ownmt 488.6 -> 305.0 ms (-38%) on x64,
28.0 -> 14.6 ms (-48%) on arm64**. ownmt only reaches the *new* rotating
cost, not the old one.

Classic set (base/ours, >1 means ours slower):
nbody 0.999, spectral-norm 1.002, fannkuch 1.003, binary-trees 0.972,
fasta 1.106, **deltablue 0.875 (~14% slower)**, scimark 0.999.

## Conclusion: STOP (not landed)

The flag is exact and fixes ownmt, but it cannot be used without making the
`__index` metamethod lookup structural on the runtime metatable, and that
costs the common shared-class case far more than the 2% budget (rotating
+102%, deltablue +14%). main's `8b90f907` deliberately hard-codes the lookup
to the *constant* metatable behind the identity guard to hoist it out of the
loop; ownmt requires the opposite. An exact flag alone does not resolve the
tension, so nothing is landed.

## Open for the next round (short list)

1. Two-guard scheme: keep the primary trace on the identity guard + constant
   lookup (fast rotating), and record the *side* trace that fills a
   metatable-identity exit with the weakness flag + structural lookup. The
   side trace then covers all metatables that share the weakness. Needs a
   recorder signal for "parent exit was a metatable identity guard" and the
   flag maintenance above.
2. If that is not wanted, accept ownmt as-is (it is correct; it is only
   slow) and remove the ownmt finding from the perf list, or document it as
   a known cost with the numbers above.
3. `LJ_TAB_WEAK_UNKNOWN` and the choke points above are the required set for
   any future flag. `tests/d54/weak_mode_paths.lua` pins the observable
   behaviour of every one of those paths (it is green on main too, because
   main's `__mode` HREF guard already covers them; it is the red-first guard
   for the flag implementation).
