# ownmt: shared-property weak guard — findings, not landed

Goal: the ownmt method-call case (objects with one metatable each) is ~2x
slower than before the weak-table fix, because rec_tabguard guards the
metatable identity, so a trace recorded for one metatable exits for every
other metatable of the loop.

Candidate tried: replace the identity guard with a guard on an exact
per-metatable `weak` flag (shared by all metatables with the same weakness),
so the loop does not exit per metatable. Implemented and reverted:

- GCtab gains `uint8_t weak`; IRFL_TAB_WEAK; `lj_tab_updweak(g,t,key,val)`.
- rec_tabguard guards `FLOAD meta.weak` vs the record-time flag, and recomputes
  the flag from the metatable's `__mode` (covers tables built by TDUP from a
  parse-time template, which no store hook sees).
- lua_rawset / lua_setfield / lua_settable call lj_tab_updweak.
- BC_TSETS calls lj_tab_updweak for the interned __mode key.

Result: 5 of 7 weak_* tests green, but the approach is NOT safe:

- `weak_mode_tsets` (`mt.__mode = "kv"`, a NEW key) fails. On the BC_TSETS
  new-key path `lj_tab_newkey` returns in rax = RC, so the key register
  `STR:RC` is clobbered before the store at label 3 where the flag would be
  updated. The tagged key is only on the stack (`TMP1`). Using that stack copy
  (cleartp + compare) made `weak_metatable_mode` and `weak_mt_store_traces`
  SIGSEGV (rc=139), so the register/stack discipline of that path needs a
  careful rework, not a quick patch.
- The store-path list that must maintain the flag exactly is broad: the VM
  BC_TSETS fast path (existing-key and new-key), the BC_TSETS slow path
  (vmeta_tsets / lj_meta_tset), lua_rawset, lua_rawseti, lua_setfield,
  lua_settable, lua_seti, rawset, the parser's constant-table template (TDUP),
  lj_tab_dup, and any internal lj_tab_set/lj_tab_setstr caller that writes the
  __mode key. A missed path is a wrong collection, which the operator rules
  out.

Decision: revert to integ6 and report instead of forcing it. The ownmt
micro-case stays ~2x; that is acceptable, a wrong collection is not.

## Pre-existing, not caused by this work

`tests/d54/weak_metatable_mode.lua` (added during guardperf) fails on integ6
too (joff=1 jon=1): a strong class metatable gains __mode after the method-call
loop was compiled and the weak entry is not collected. It needs its own triage;
it is not in tests/known-bad.tsv.

## If someone picks this up

The exact-flag design is sound; the blocker is the BC_TSETS new-key path. One
clean way is to move the flag update into `lj_tab_newkey` (which knows the key
and can read the value from the returned slot's caller) and into a single
`lj_tab_setstr` choke point plus the C API setters, rather than patching the
dynasm store. Verify with weak_mode_tsets, weak_mode_rawset, weak_setmt_after,
weak_str2weak, weak_mt_store_traces and the new per-store red tests.
