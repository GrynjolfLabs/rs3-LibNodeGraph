-- Test entry point. Run from anywhere with a standalone Lua interpreter:
--   lua LibNodeGraph/tests/run.lua
-- Exit code is 0 on success, non-zero on any test failure (suitable for CI).

local function scriptDir()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("^@(.*)$") or ""
    return path:match("(.*[/\\])") or "./"
end

local testsDir = scriptDir()
local rootDir = testsDir .. "../"

package.path = rootDir .. "?.lua;" .. testsDir .. "?.lua;" .. package.path

local luaunit = require("luaunit")

require("test_registry")
require("test_graph")
require("test_json")
require("test_serialize")
require("test_modes")

os.exit(luaunit.LuaUnit.run())
