#!/usr/bin/env python3
"""Seeded generator of valid Lua 5.4 programs for differential fuzzing.

Every program is deterministic (no io/os/random), bounded (loops <= 6 iterations,
expression depth <= 3) and prints labeled results, so two implementations can be
compared byte-for-byte after the harness normalization.

  gen.py --seed 1 --mode mixed --gc --out prog.lua
"""
import argparse
import random

INTS = ["0", "1", "-1", "2", "7", "-7", "255", "65536", "2147483647",
        "4611686018427387904", "9223372036854775807", "-9223372036854775808",
        "9007199254740993", "1000000000000000000"]
FLOATS = ["0.0", "-0.0", "1.0", "-1.5", "0.1", "3.5", "1e15", "1e16", "1e308",
          "1e-308", "2.0^53", "math.huge", "-math.huge", "0.5", "1e18"]
BINOPS = ["+", "-", "*", "/", "%", "^"]
BINOPS54 = ["//", "&", "|", "~", "<<", ">>"]
PRE = """\
local function s(e) return (tostring(e):gsub("^.-:%d+: ", "")) end
local function p(l, ok, ...)
  local n, t = select("#", ...), {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  print(l .. " | " .. tostring(ok) .. " | " .. table.concat(t, " | "))
end
local function try(f) local ok, a, b = pcall(f); if ok then return true, a, b end
  return false, s(a) end
local TR = {}
local function mm(tag) return function(a, b) TR[#TR+1] = tag; return 17 end end
local OBJ = setmetatable({}, {__add=mm("add"), __sub=mm("sub"), __mul=mm("mul"),
  __div=mm("div"), __mod=mm("mod"), __pow=mm("pow"), __idiv=mm("idiv"),
  __band=mm("band"), __bor=mm("bor"), __bxor=mm("bxor"), __shl=mm("shl"),
  __shr=mm("shr"), __bnot=mm("bnot"), __unm=mm("unm"), __len=mm("len"),
  __eq=mm("eq"), __lt=mm("lt"), __le=mm("le"), __concat=mm("concat")})
local PLAIN = setmetatable({}, {})
local acc = 0
"""


class Gen:
    def __init__(self, rnd, mode, gc):
        self.r, self.mode, self.gc = rnd, mode, gc
        self.ops = BINOPS + (BINOPS54 if mode in ("bits", "mixed", "numeric54") else [])

    def leaf(self):
        r = self.r
        c = r.random()
        if c < 0.40:
            return r.choice(INTS)
        if c < 0.70:
            return r.choice(FLOATS)
        if c < 0.78:
            return r.choice(['"3"', '"0x10"', '"  12  "', '"abc"', '"1e2"'])
        if c < 0.86:
            return r.choice(["OBJ", "PLAIN"])
        if c < 0.93:
            return "acc"
        return r.choice(["math.maxinteger", "math.mininteger", "2^53", "#'abcd'"])

    def expr(self, d=0):
        r = self.r
        if d >= 3 or r.random() < 0.35:
            return self.leaf()
        c = r.random()
        if c < 0.55:
            return "(%s %s %s)" % (self.expr(d + 1), r.choice(self.ops), self.expr(d + 1))
        if c < 0.65:
            return "(%s %s)" % (r.choice(["-", "~", "#"]), self.expr(d + 1))
        if c < 0.75:
            return "(%s %s %s)" % (self.expr(d + 1), r.choice(["<", "<=", ">", ">=", "==", "~="]), self.expr(d + 1))
        if c < 0.85:
            return "%s(%s)" % (r.choice(["tostring", "tonumber", "math.type", "math.tointeger",
                                         "math.abs", "math.floor", "math.sqrt"]), self.expr(d + 1))
        if c < 0.93:
            return "string.format(%s, %s)" % (r.choice(['"%d"', '"%g"', '"%a"', '"%x"', '"%s"', '"%.3f"']), self.expr(d + 1))
        return "(%s .. %s)" % (self.expr(d + 1), self.expr(d + 1))

    def stmt(self, i):
        r = self.r
        e = self.expr()
        out = []
        if self.gc and r.random() < 0.25:
            out.append(r.choice(['collectgarbage("step", %d)' % r.randint(1, 50),
                                 'collectgarbage("collect")',
                                 'do local w = setmetatable({}, {__mode="v"}) w[1] = {} end']))
        c = r.random()
        if c < 0.60:
            out.append('p("e%d", try(function() return %s end))' % (i, e))
        elif c < 0.75:
            out.append('p("f%d", try(function() return string.format("%s", %s) end))'
                       % (i, r.choice(["%d", "%g", "%a", "%x", "%s", "%q"]), e))
        elif c < 0.90:
            k = r.randint(1, 6)
            out.append('for i%d = 1, %d do acc = acc + (i%d %% 3) end' % (i, k, i))
            out.append('p("loop%d", true, acc)' % i)
        elif c < 0.97:
            # Overflowing int arithmetic in a hot loop (JIT must match the
            # interpreter's 64-bit wrap and bit-op semantics).
            seed = r.choice([12345, 1, -5, 99991])
            mul = r.choice([1103515245, 0x7fffffff, 0x100000001b3, 0x40000001])
            inc = r.choice([12345, 1, 7, 0x7ffffff])
            mask = r.choice([0x7fffffff, 0xffffffff, 0x3fffffff])
            out.append('do local q = %d; for j = 1, 200 do q = (q * %d + %d) & %d end '
                       'p("lcg%d", true, q, math.type(q)) end' % (seed, mul, inc, mask, i))
        else:
            out.append('p("t%d", try(function() local t = {%s, %s, %s} return #t, t[1], t[2] end))'
                       % (i, self.leaf(), self.leaf(), self.leaf()))
        return "\n".join(out)

    def program(self, n):
        body = [PRE]
        for i in range(n):
            body.append(self.stmt(i))
        body.append('p("trace", true, table.concat(TR, ","))')
        body.append('p("acc", true, acc)')
        if self.gc:
            body.append('collectgarbage("collect")\np("gcount", true, collectgarbage("count") > 0)')
        return "\n".join(body) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--mode", default="mixed", choices=["numeric", "numeric54", "bits", "meta", "mixed"])
    ap.add_argument("--gc", action="store_true")
    ap.add_argument("--stmts", type=int, default=18)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    g = Gen(random.Random(a.seed), a.mode, a.gc)
    with open(a.out, "w") as f:
        f.write(g.program(a.stmts))


if __name__ == "__main__":
    main()
