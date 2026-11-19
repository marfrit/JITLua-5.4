--! §6.4 an error object that is not a string reaches the standalone message
--! handler. Like PUC 5.4.9 (lua.c msghandler) it may call __tostring, but only
--! a string result is used as the message; anything else is reported as
--! "(error object is a table value)". Numbers are converted by lua_tostring.
--! The traceback is cut by the harness before comparing; only the message line
--! and the exit status are compared.
error(setmetatable({}, { __tostring = function() return 42 end }))
