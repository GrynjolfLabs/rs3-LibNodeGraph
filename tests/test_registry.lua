local luaunit = require("luaunit")
local Registry = require("registry")

TestRegistry = {}

function TestRegistry:setUp()
    self.registry = Registry.new()
end

function TestRegistry:testRegisterNodeTypeStoresPinsAndOrder()
    local nodeType = self.registry:RegisterNodeType("test.echo", {
        category = "pure",
        displayName = "Echo",
        pins = {
            { name = "in", kind = "data", direction = "in", dataType = "number", default = 5 },
            { name = "out", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            ctx:Out("out", ctx:In("in"))
        end,
    })

    luaunit.assertEquals(nodeType.key, "test.echo")
    luaunit.assertEquals(nodeType.category, "pure")
    luaunit.assertEquals(nodeType.displayName, "Echo")
    luaunit.assertEquals(nodeType.pinOrder, { "in", "out" })
    luaunit.assertEquals(nodeType.pins["in"].kind, "data")
    luaunit.assertEquals(nodeType.pins["in"].default, 5)
    luaunit.assertEquals(nodeType.pins["out"].direction, "out")

    luaunit.assertIs(self.registry:GetNodeType("test.echo"), nodeType)
end

function TestRegistry:testDisplayNameDefaultsToKey()
    local nodeType = self.registry:RegisterNodeType("test.bare", {
        pins = {},
        run = function() end,
    })
    luaunit.assertEquals(nodeType.displayName, "test.bare")
end

function TestRegistry:testRequiresRunFunction()
    luaunit.assertErrorMsgContains("must define run", function()
        self.registry:RegisterNodeType("test.norun", { pins = {} })
    end)
end

function TestRegistry:testRequiresNonEmptyKey()
    luaunit.assertError(function()
        self.registry:RegisterNodeType("", { pins = {}, run = function() end })
    end)
end

function TestRegistry:testRejectsDuplicatePinNames()
    luaunit.assertErrorMsgContains("duplicate pin", function()
        self.registry:RegisterNodeType("test.dup", {
            pins = {
                { name = "a", kind = "data", direction = "in" },
                { name = "a", kind = "data", direction = "out" },
            },
            run = function() end,
        })
    end)
end

function TestRegistry:testRejectsInvalidPinKind()
    luaunit.assertErrorMsgContains("kind", function()
        self.registry:RegisterNodeType("test.badkind", {
            pins = { { name = "a", kind = "banana", direction = "in" } },
            run = function() end,
        })
    end)
end

function TestRegistry:testRejectsInvalidPinDirection()
    luaunit.assertErrorMsgContains("direction", function()
        self.registry:RegisterNodeType("test.baddir", {
            pins = { { name = "a", kind = "data", direction = "sideways" } },
            run = function() end,
        })
    end)
end

function TestRegistry:testGetNodeTypeUnknownReturnsNil()
    luaunit.assertIsNil(self.registry:GetNodeType("does.not.exist"))
end

function TestRegistry:testGetNodeTypesByCategoryFilters()
    self.registry:RegisterNodeType("test.trig1", {
        category = "trigger",
        pins = {},
        run = function() end,
    })
    self.registry:RegisterNodeType("test.trig2", {
        category = "trigger",
        pins = {},
        run = function() end,
    })
    self.registry:RegisterNodeType("test.act1", {
        category = "action",
        pins = {},
        run = function() end,
    })

    local triggers = self.registry:GetNodeTypesByCategory("trigger")
    luaunit.assertEquals(#triggers, 2)

    local none = self.registry:GetNodeTypesByCategory("nonexistent")
    luaunit.assertEquals(#none, 0)
end

function TestRegistry:testUnknownTypeIsRegisteredAndHidden()
    local unknown = self.registry:GetNodeType(Registry.UNKNOWN_TYPE)
    luaunit.assertNotIsNil(unknown)
    luaunit.assertEquals(unknown.hidden, true)
    luaunit.assertEquals(unknown.pinOrder, {})
    -- No-op run: callable, sets nothing.
    luaunit.assertEquals(type(unknown.run), "function")
end

function TestRegistry:testUnknownTypeKeyIsReservedFromRegistration()
    luaunit.assertErrorMsgContains("reserved", function()
        self.registry:RegisterNodeType(Registry.UNKNOWN_TYPE, {
            category = "trigger",
            pins = {},
            run = function() end,
        })
    end)
end

function TestRegistry:testHiddenTypesExcludedFromCategoryQuery()
    self.registry:RegisterNodeType("test.visible", {
        category = "misc",
        pins = {},
        run = function() end,
    })
    self.registry:RegisterNodeType("test.secret", {
        category = "misc",
        hidden = true,
        pins = {},
        run = function() end,
    })

    local misc = self.registry:GetNodeTypesByCategory("misc")
    luaunit.assertEquals(#misc, 1)
    luaunit.assertEquals(misc[1].key, "test.visible")
end

function TestRegistry:testDataTypeRoundTrip()
    local coordType = {
        encode = function(v) return v.x .. "," .. v.y end,
        decode = function(s)
            local x, y = s:match("(-?%d+),(-?%d+)")
            return { x = tonumber(x), y = tonumber(y) }
        end,
    }
    self.registry:RegisterDataType("coord", coordType)
    luaunit.assertIs(self.registry:GetDataType("coord"), coordType)
end

function TestRegistry:testGetDataTypeUnknownOrNilReturnsNil()
    luaunit.assertIsNil(self.registry:GetDataType("unregistered"))
    luaunit.assertIsNil(self.registry:GetDataType(nil))
end

return TestRegistry
