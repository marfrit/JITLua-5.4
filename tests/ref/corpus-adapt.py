#!/usr/bin/env python3
"""Reapply the deliberate local adaptations to the vendored PUC testes corpus.

Run by tests/ref/fetch-ref.sh --corpus after extracting the upstream suite.
Four divergence classes are intentional (see docs/phase0-status.md):
- constructs.lua: a fixed GLOB1, because math.random output differs per process
  and would make every differential arm flaky.
- literals.lua / pm.lua: no %p / lua_topointer identity assertion for long
  strings; LuaJIT interns every string while PUC does not intern long strings.
- math.lua / sort.lua: omit PRNG seeds/statistics and timing/comparison-count
  prints; these are process- or implementation-defined across arms, while the
  corresponding assertions still run.
"""
import sys

root = sys.argv[1] if len(sys.argv) > 1 else 'tests/corpus/puc54'


def patch(name, old, new):
    path = root + '/' + name
    s = open(path).read()
    if old not in s:
        raise SystemExit('corpus-adapt: pattern not found in ' + name)
    open(path, 'w').write(s.replace(old, new, 1))


patch('constructs.lua',
      '_ENV.GLOB1 = math.random(0, 1)',
      '_ENV.GLOB1 = 0  -- fixed (was math.random(0,1); output must be deterministic)')

patch('literals.lua',
      'assert(sd == s1 and getadd(sd) ~= a1)',
      'assert(sd == s1)\n'
      '  -- Deliberate divergence: LuaJIT interns every string, PUC does not '
      'intern\n  -- long strings, so the %p/lua_topointer identity after concat '
      'differs.')

patch('math.lua',
      '  print(string.format("random seeds: %d, %d", x, y))',
      '  -- Not printed: the seed is OS/process-dependent (IMPL-DEFINED).')
patch('math.lua',
      '  print(string.format("float random range in %d calls: [%f, %f]",\n'
      '                      totalrounds, low, up))',
      '  -- No print: PRNG/process-dependent statistics (IMPL-DEFINED).')
patch('math.lua',
      '  print(string.format(\n'
      '     "integer random range in %d calls: [minint + %.0fppm, maxint - %.0fppm]",\n'
      '      totalrounds, (minint - low) / minint * 1e6,\n'
      '                   (maxint - up) / maxint * 1e6))',
      '  -- No print: PRNG/process-dependent statistics (IMPL-DEFINED).')

patch('sort.lua',
      '  print(string.format("%ssorting %d %s elements in %.2f msec.", pre, n, msg, x))',
      '  -- No timing print: implementation-defined across arms.')
patch('sort.lua',
      'print(string.format("Invert-sorting other %d elements in %.2f msec., with %i comparisons",\n'
      '      limit, x, i))',
      '-- No timing/comparison print (implementation-defined across arms).')

patch('pm.lua',
      'assert(r == s and string.format("%p", s) ~= string.format("%p", r))',
      'assert(r == s)\n'
      '  -- Deliberate divergence: LuaJIT interns every string (PUC does not '
      'intern\n  -- long strings), so the %p/lua_topointer identity assertion '
      'is skipped.')
