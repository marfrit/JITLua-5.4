# guardperf notes

Goal: recover the method-call cost of the weak-table runtime guard
(lj_record.c rec_tabguard) introduced by the weak-table JIT fix, without
weakening the weak_*.lua semantics.

Base: 7b85747e (pre-fix). Head: this branch on 9073ddc8 (merged main).
Method-call micro-bench: tests/bench/method_call.lua.

## Root cause (x64 -jdump=+rs)

The guard emits, per indexed table operand, `FLOAD tab.meta; EQ meta, {Class}`
plus a hoisted `__mode` lookup on the constant metatable. The rotating
method-call loop (objects sharing one class metatable) re-executed the
metatable identity guard every iteration; the __index chain already emits
`FLOAD tab.meta; NE NULL`, so the loop paid one extra load/compare per
iteration (plus a second guard on the class table itself from the metamethod
lookup). Fixed receiver: the guard is hoisted (0%).

## Changes

1. rec_idx guards only the original table operand, not the metamethod-chain
   metaobjects (guardtab flag); lj_record_mm_lookup uses rec_idx(..., 0).
   A metaobject's entries are already guarded by the shape guards
   (HREFK/HLOAD/EQ).
2. lj_record_mm_lookup guards the metatable identity (EQ ktab(mt)) instead of
   NE NULL. The folder CSEs it with rec_tabguard's identity guard, so the
   class idiom pays one guard on the metatable load the __index chain already
   does, not two.

Result loop (x64): `ALOAD; FLOAD meta; EQ {Class}; HREF "get"; EQ; FLOAD
meta.hmask; ...` = the base loop's instruction count (the base's `NE NULL` is
replaced by the identity guard); the `__mode` lookup is hoisted to the
prologue.

## Numbers (interleaved in one job, median of 7, pinned x64)

method_call, base 7b85747e -> head:
  plain 0.0%   field +1.1%   fixed -0.5%   rotating -2.4% (was +11.4%)
  ownmt +103%  (objects with one metatable each: the identity guard exits per
                metatable; not addressed, would need a per-operand weakness
                check instead of an identity check)
Classic set: nbody -0.3, spectral-norm +0.1, fannkuch 0.0, binary-trees 0.0,
fasta -0.1, deltablue -11.8, scimark +0.2, k-nucleotide 0.0, regex-dna 0.0 (%).

arm64 (noisier): rotating +2.4%, plain -0.5%, fixed -32%, field +18%,
ownmt +118%. Treat the arm deltas under ~10% as noise.

## Tests / gates

tests/d54/weak_metatable_mode.lua is RED on 7b85747e (a strong class metatable
gains __mode after the loop was compiled, by rawset, TSETS, setmetatable swap
and a shared metatable; the weak entry must still be collected). weak_* 23/23,
env_* 24/24. ci-box and ci-local --sanitizers-only pass on x64 and arm64.

## Merged main

9073ddc8 guards the raw non-table _ENV value with a new FLOAD FUNC_ENVV and
dropped the env flushes; this branch keeps the B2 `FUNC_ENV != NULL` table-path
guard and adds only the two changes above.
