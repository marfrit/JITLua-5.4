--! §5 the file-handle metatable: PUC keeps the methods under __index and puts
--! no method directly in the metatable; only __index, __name, __close, __gc,
--! __tostring are direct keys. Differential against PUC 5.4.9.
local mt = getmetatable(io.stdout)
local ks = {}
for k in pairs(mt) do ks[#ks + 1] = tostring(k) end
table.sort(ks)
print("keys | " .. table.concat(ks, ","))
print("direct write | " .. tostring(rawget(mt, "write")))
print("direct read | " .. tostring(rawget(mt, "read")))
print("direct close | " .. tostring(rawget(mt, "close")))
print("index type | " .. type(rawget(mt, "__index")))
print("index write | " .. type(rawget(rawget(mt, "__index"), "write")))
print("name | " .. tostring(rawget(mt, "__name")))
print("method call | " .. tostring(io.stdout:write("") == io.stdout))
print("getmetatable stdin | " .. tostring(getmetatable(io.stdin) == mt))
