Vendored from the official Lua 5.4 test suite (`testes/`), lua/lua GitHub mirror,
tag `v5.4.9`, commit `312b9efaa1061c2c4cad08554dbc1351c3270eef`.
Copyright Lua.org, PUC-Rio — see the Copyright Notice in `all.lua` (MIT-style Lua license).
Re-extract with `tests/ref/fetch-ref.sh --corpus`; it reapplies the three deliberate local adaptations (constructs GLOB1 fixed; literals/pm skip %p identity because LuaJIT interns all strings), via tests/ref/corpus-adapt.py.
Files using the internal `T.*` test hooks (ltests.c) are auto-skipped by the harness.
