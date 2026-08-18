local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")

TestModes = {}

function TestModes:setUp()
    self.registry = Registry.new()
end

local function inventoryModes()
    return {
        {
            key = "full",
            label = "Full",
            pins = {
                { name = "out", kind = "exec", direction = "out" },
                { name = "item", kind = "data", direction = "out", dataType = "any" },
                { name = "count", kind = "data", direction = "out", dataType = "number" },
            },
        },
        {
            key = "count",
            label = "Count",
            pins = {
                { name = "out", kind = "exec", direction = "out" },
                { name = "n", kind = "data", direction = "out", dataType = "number" },
            },
        },
    }
end

function TestModes:testRegisterModesExposesDefaultPinSetOnTheType()
    local nodeType = self.registry:RegisterNodeType("test.inv", {
        category = "trigger",
        modes = inventoryModes(),
        defaultMode = "full",
        run = function() end,
    })

    luaunit.assertEquals(nodeType.defaultMode, "full")
    luaunit.assertEquals(nodeType.pinOrder, { "out", "item", "count" })
    luaunit.assertEquals(nodeType.pins["item"].kind, "data")
    luaunit.assertEquals(nodeType.modes.full.label, "Full")
    luaunit.assertEquals(nodeType.modes.count.pinOrder, { "out", "n" })
    luaunit.assertEquals(nodeType.modes.count.pins["n"].dataType, "number")
end

function TestModes:testRegisterRejectsPinsAndModesTogether()
    luaunit.assertErrorMsgContains("both pins and modes", function()
        self.registry:RegisterNodeType("test.both", {
            pins = { { name = "a", kind = "data", direction = "in" } },
            modes = inventoryModes(),
            defaultMode = "full",
            run = function() end,
        })
    end)
end

function TestModes:testRegisterRejectsModesWithoutDefaultMode()
    luaunit.assertErrorMsgContains("defaultMode", function()
        self.registry:RegisterNodeType("test.nodefault", {
            modes = inventoryModes(),
            run = function() end,
        })
    end)
end

function TestModes:testRegisterRejectsDuplicateModeKeys()
    luaunit.assertErrorMsgContains("duplicate mode key", function()
        self.registry:RegisterNodeType("test.dupmode", {
            modes = {
                { key = "full", label = "A", pins = {} },
                { key = "full", label = "B", pins = {} },
            },
            defaultMode = "full",
            run = function() end,
        })
    end)
end

function TestModes:testRegisterRejectsMismatchedSameNamePinsAcrossModes()
    luaunit.assertErrorMsgContains("must match", function()
        self.registry:RegisterNodeType("test.mismatch", {
            modes = {
                {
                    key = "a",
                    pins = { { name = "v", kind = "data", direction = "out", dataType = "number" } },
                },
                {
                    key = "b",
                    pins = { { name = "v", kind = "data", direction = "out", dataType = "string" } },
                },
            },
            defaultMode = "a",
            run = function() end,
        })
    end)
end

function TestModes:testTypeWithoutModesLeavesGetModeNil()
    self.registry:RegisterNodeType("test.plain", {
        pins = { { name = "a", kind = "data", direction = "in", dataType = "number", default = 1 } },
        run = function() end,
    })
    local graph = Graph.new(self.registry)
    local id = graph:AddNode("test.plain")
    luaunit.assertIsNil(graph:GetMode(id))
    luaunit.assertEquals(graph:GetPins(id)[1].name, "a")
end

local function registerInventory(registry, run)
    return registry:RegisterNodeType("test.inv", {
        category = "trigger",
        modes = inventoryModes(),
        defaultMode = "full",
        run = run or function() end,
    })
end

function TestModes:testAddNodeUsesDefaultModeAndGetPinsFollowsIt()
    registerInventory(self.registry)
    local graph = Graph.new(self.registry)
    local id = graph:AddNode("test.inv")
    luaunit.assertEquals(graph:GetMode(id), "full")
    local pins = graph:GetPins(id)
    luaunit.assertEquals(#pins, 3)
    luaunit.assertEquals(pins[1].name, "out")
    luaunit.assertEquals(pins[2].name, "item")
    luaunit.assertEquals(pins[3].name, "count")
end

function TestModes:testAddNodeAcceptsExplicitMode()
    registerInventory(self.registry)
    local graph = Graph.new(self.registry)
    local id = graph:AddNode("test.inv", nil, "count")
    luaunit.assertEquals(graph:GetMode(id), "count")
    local pins = graph:GetPins(id)
    luaunit.assertEquals(#pins, 2)
    luaunit.assertEquals(pins[2].name, "n")
end

function TestModes:testConnectFollowsActiveModePins()
    registerInventory(self.registry)
    self.registry:RegisterNodeType("test.sink", {
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() end,
    })
    local graph = Graph.new(self.registry)
    local src = graph:AddNode("test.inv", nil, "count")
    local sink = graph:AddNode("test.sink")
    local ok, reason = graph:Connect(src, "item", sink, "in")
    luaunit.assertIsNil(ok)
    luaunit.assertEquals(reason, "unknown_pin")
    local connId = graph:Connect(src, "out", sink, "in")
    luaunit.assertNotIsNil(connId)
end

function TestModes:testSetModeUnknownKeyIsNoOp()
    registerInventory(self.registry)
    local graph = Graph.new(self.registry)
    local id = graph:AddNode("test.inv")
    luaunit.assertEquals(graph:SetMode(id, "nope"), false)
    luaunit.assertEquals(graph:GetMode(id), "full")
end

function TestModes:testSetModeDropsVanishedWiresAndKeepsSharedPin()
    registerInventory(self.registry)
    self.registry:RegisterNodeType("test.execsink", {
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function() end,
    })
    self.registry:RegisterNodeType("test.datasink", {
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "v", kind = "data", direction = "in", dataType = "any", default = nil },
        },
        run = function() end,
    })
    local graph = Graph.new(self.registry)
    local src = graph:AddNode("test.inv")
    local execSink = graph:AddNode("test.execsink")
    local dataSink = graph:AddNode("test.datasink")
    graph:Connect(src, "out", execSink, "in")
    graph:Connect(src, "item", dataSink, "v")

    luaunit.assertEquals(graph:SetMode(src, "count"), true)
    luaunit.assertEquals(graph:GetMode(src), "count")

    local conns = graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].fromPin, "out")
    luaunit.assertEquals(conns[1].toNode, execSink)
end

function TestModes:testSetModeDropsVanishedControlsAndSeedsNewDefaults()
    self.registry:RegisterNodeType("test.switch", {
        modes = {
            {
                key = "a",
                pins = {
                    { name = "shared", kind = "data", direction = "in", dataType = "number", default = 1 },
                    { name = "onlyA", kind = "data", direction = "in", dataType = "number", default = 2 },
                },
            },
            {
                key = "b",
                pins = {
                    { name = "shared", kind = "data", direction = "in", dataType = "number", default = 1 },
                    { name = "onlyB", kind = "data", direction = "in", dataType = "number", default = 3 },
                },
            },
        },
        defaultMode = "a",
        run = function() end,
    })
    local graph = Graph.new(self.registry)
    local id = graph:AddNode("test.switch", { shared = 9, onlyA = 8 })
    graph:SetMode(id, "b")
    luaunit.assertEquals(graph:GetControl(id, "shared"), 9)
    luaunit.assertIsNil(graph:GetControl(id, "onlyA"))
    luaunit.assertEquals(graph:GetControl(id, "onlyB"), 3)
end

function TestModes:testFireUsesActiveModeAndExposesCtxMode()
    local seen = {}
    registerInventory(self.registry, function(ctx)
        seen.mode = ctx.mode
        ctx:Out("n", 7)
        ctx:Fire("out")
    end)
    self.registry:RegisterNodeType("test.probe", {
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "v", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function(ctx)
            seen.value = ctx:In("v")
        end,
    })
    local graph = Graph.new(self.registry)
    local src = graph:AddNode("test.inv", nil, "count")
    local probe = graph:AddNode("test.probe")
    graph:Connect(src, "out", probe, "in")
    graph:Connect(src, "n", probe, "v")
    graph:Fire(src)
    luaunit.assertEquals(seen.mode, "count")
    luaunit.assertEquals(seen.value, 7)
end

function TestModes:testCtxModeIsNilWhenTypeHasNoModes()
    local seen
    self.registry:RegisterNodeType("test.trig", {
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx)
            seen = ctx.mode
            ctx:Fire("out")
        end,
    })
    local graph = Graph.new(self.registry)
    graph:Fire(graph:AddNode("test.trig"))
    luaunit.assertIsNil(seen)
end

function TestModes:testSerializeRoundTripsMode()
    registerInventory(self.registry)
    local graph = Graph.new(self.registry)
    local id = graph:AddNode("test.inv", nil, "count")
    local data = Serialize.Serialize(graph)
    luaunit.assertEquals(data.nodes[1].mode, "count")
    luaunit.assertEquals(data.version, 1)

    local restored = Serialize.Deserialize(data, self.registry)
    luaunit.assertEquals(restored:GetMode(id), "count")
    luaunit.assertEquals(restored:GetPins(id)[2].name, "n")
end

function TestModes:testDeserializeMissingModeUsesDefault()
    registerInventory(self.registry)
    local restored = Serialize.Deserialize({
        version = 1,
        nodes = { { id = 1, type = "test.inv", controls = {} } },
        connections = {},
    }, self.registry)
    luaunit.assertEquals(restored:GetMode(1), "full")
end

function TestModes:testSerializeOmitsModeWhenTypeHasNone()
    self.registry:RegisterNodeType("test.plain", {
        pins = {},
        run = function() end,
    })
    local graph = Graph.new(self.registry)
    graph:AddNode("test.plain")
    local data = Serialize.Serialize(graph)
    luaunit.assertIsNil(data.nodes[1].mode)
end

function TestModes:testPlaceholderRoundTripPreservesMode()
    local data = {
        version = 1,
        nodes = { { id = 1, type = "test.inv", controls = {}, mode = "count" } },
        connections = {},
    }
    local empty = Registry.new()
    local placeholder = Serialize.Deserialize(data, empty, { onUnknown = "placeholder" })
    local resaved = Serialize.Serialize(placeholder)
    luaunit.assertEquals(resaved.nodes[1].type, "test.inv")
    luaunit.assertEquals(resaved.nodes[1].mode, "count")

    registerInventory(self.registry)
    local restored = Serialize.Deserialize(resaved, self.registry)
    luaunit.assertEquals(restored:GetMode(1), "count")
end

return TestModes
