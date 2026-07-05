local luaunit = require("luaunit")
local Json = require("json")

TestJson = {}

function TestJson:testEncodeDecodePrimitives()
    luaunit.assertEquals(Json.Bundled.decode(Json.Bundled.encode(true)), true)
    luaunit.assertEquals(Json.Bundled.decode(Json.Bundled.encode(false)), false)
    luaunit.assertEquals(Json.Bundled.decode(Json.Bundled.encode(42)), 42)
    luaunit.assertEquals(Json.Bundled.decode(Json.Bundled.encode(-3.5)), -3.5)
    luaunit.assertIsNil(Json.Bundled.decode(Json.Bundled.encode(nil)))
end

function TestJson:testEncodeDecodeStringWithEscapes()
    local original = "hello \"world\"\n\t\\ backslash"
    local encoded = Json.Bundled.encode(original)
    luaunit.assertEquals(Json.Bundled.decode(encoded), original)
end

function TestJson:testEncodeDecodeControlCharacter()
    local original = "bell:\a"
    local encoded = Json.Bundled.encode(original)
    luaunit.assertStrContains(encoded, "\\u0007")
    luaunit.assertEquals(Json.Bundled.decode(encoded), original)
end

function TestJson:testEncodeArray()
    local encoded = Json.Bundled.encode({ 1, 2, 3 })
    luaunit.assertEquals(encoded, "[1,2,3]")
    luaunit.assertEquals(Json.Bundled.decode(encoded), { 1, 2, 3 })
end

function TestJson:testEncodeObject()
    local decoded = Json.Bundled.decode(Json.Bundled.encode({ a = 1, b = "two" }))
    luaunit.assertEquals(decoded.a, 1)
    luaunit.assertEquals(decoded.b, "two")
end

function TestJson:testNestedStructures()
    local original = {
        version = 1,
        nodes = {
            { id = 1, type = "trigger.manual", controls = { x = 1, y = 2 } },
            { id = 2, type = "action.log", controls = {} },
        },
    }
    local decoded = Json.Bundled.decode(Json.Bundled.encode(original))
    luaunit.assertEquals(decoded.version, 1)
    luaunit.assertEquals(#decoded.nodes, 2)
    luaunit.assertEquals(decoded.nodes[1].type, "trigger.manual")
    luaunit.assertEquals(decoded.nodes[1].controls.x, 1)
    luaunit.assertEquals(decoded.nodes[1].controls.y, 2)
end

function TestJson:testEmptyTableRoundTripsAsEmptyContainer()
    local decoded = Json.Bundled.decode(Json.Bundled.encode({}))
    local count = 0
    for _ in pairs(decoded) do
        count = count + 1
    end
    luaunit.assertEquals(count, 0)
end

function TestJson:testEncodeRejectsNonStringObjectKeys()
    luaunit.assertError(function()
        Json.Bundled.encode({ [1] = "a", [3] = "b" }) -- sparse: not a valid array or string-keyed object
    end)
end

function TestJson:testSetDefaultRequiresEncodeAndDecodeFunctions()
    luaunit.assertError(function()
        Json.SetDefault({ encode = function() end })
    end)
end

function TestJson:testSetDefaultSwapsCodecAndIsRestorable()
    local original = Json.Default
    local calls = { encode = 0, decode = 0 }
    local stub = {
        encode = function(v)
            calls.encode = calls.encode + 1
            return original.encode(v)
        end,
        decode = function(s)
            calls.decode = calls.decode + 1
            return original.decode(s)
        end,
    }
    Json.SetDefault(stub)
    luaunit.assertIs(Json.Default, stub)

    Json.Default.encode({ 1 })
    luaunit.assertEquals(calls.encode, 1)

    -- restore, since Json is a shared module-level singleton across test files
    Json.SetDefault(original)
    luaunit.assertIs(Json.Default, original)
end

return TestJson
