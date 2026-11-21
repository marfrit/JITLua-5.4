#!/bin/sh
# GC policy mode check for JITLua-5.4.
#
#   sh tests/gcmode.sh
#
# The initial collector policy must follow LUAJIT_GC=speed|memory (read in
# luaL_newstate, so every embedder honours it) and the equivalent
# `luajit -G speed|memory` option.  speed = pause 300 / stepmul 200 (the
# measured time-first default, docs/notes/knuc-phase-align-2026-11.md);
# memory = pause 100 / stepmul 200.  -G overrides the environment, -E ignores
# it, unknown values are ignored silently, the default stays unchanged, and a
# runtime collectgarbage("setpause"/"setstepmul") still overrides either.
# The standalone interpreter starts in generational mode (like lua.c), so the
# first "incremental" reports "generational"; PUC's /4 byte storage makes
# setpause 137 report 136 and setstepmul 321 report 320 on the next read.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LUAJIT=${LUAJIT:-$ROOT/src/luajit}
PROG="$ROOT/tests/gcmode.lua"
[ -x "$LUAJIT" ] || { echo "gcmode: $LUAJIT missing -- run make -j" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
fails=0

case_run() { # case_run <label> <want_pause> <command...>
  label=$1 want=$2 shift 2
  out="$TMP/$label.out" err="$TMP/$label.err"
  if ! "$@" "$PROG" >"$out" 2>"$err"; then
    echo "FAIL $label: interpreter exited non-zero"; sed 's/^/      /' "$err"
    fails=1; return
  fi
  pause=$(sed -n 's/^pause=//p' "$out")
  stepmul=$(sed -n 's/^stepmul=//p' "$out")
  minc=$(sed -n 's/^mode_inc_prev=//p' "$out")
  mgen=$(sed -n 's/^mode_gen_prev=//p' "$out")
  ovr=$(sed -n 's/^override_pause=//p' "$out")
  ovrs=$(sed -n 's/^override_stepmul=//p' "$out")
  if [ "$pause" = "$want" ] && [ "$stepmul" = 200 ] && \
     [ "$minc" = generational ] && [ "$mgen" = incremental ] && \
     [ "$ovr" = 136 ] && [ "$ovrs" = 320 ]; then
    echo "ok   $label: pause=$pause stepmul=$stepmul mode=$minc/$mgen override=$ovr/$ovrs"
  else
    echo "FAIL $label: pause=$pause stepmul=$stepmul mode=$minc/$mgen override=$ovr/$ovrs" \
         "(want pause=$want stepmul=200 mode=generational/incremental override=136/320)"
    fails=1
  fi
  if [ -s "$err" ]; then
    echo "FAIL $label: unexpected output on stderr:"; sed 's/^/      /' "$err"
    fails=1
  fi
}

case_run default      300 env -u LUAJIT_GC "$LUAJIT"
case_run env-memory   100 env LUAJIT_GC=memory "$LUAJIT"
case_run env-speed    300 env LUAJIT_GC=speed "$LUAJIT"
case_run env-unknown  300 env LUAJIT_GC=banana "$LUAJIT"
case_run cli-memory   100 env -u LUAJIT_GC "$LUAJIT" -G memory
case_run cli-attached 100 env -u LUAJIT_GC "$LUAJIT" -Gmemory
case_run cli-speed    300 env LUAJIT_GC=memory "$LUAJIT" -G speed
case_run env-vs-cli   300 env LUAJIT_GC=memory "$LUAJIT" -G speed
case_run noenv-E      300 env LUAJIT_GC=memory "$LUAJIT" -E
case_run cli-unknown  300 env -u LUAJIT_GC "$LUAJIT" -G banana

if [ "$fails" -ne 0 ]; then
  echo "gcmode: FAILED"
  exit 1
fi
echo "gcmode: OK"
