local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")

TestSerialize = {}

local function buildRegistry()
    local registry = Registry.new()

    registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })

    registry:RegisterNodeType("fixture.add", {
        category = "pure",
        pins = {
            { name = "a", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "b", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "sum", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            ctx:Out("sum", ctx:In("a") + ctx:In("b"))
        end,
    })

    registry:RegisterNodeType("fixture.action", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "value", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function() end,
    })

    registry:RegisterNodeType("fixture.coord", {
        category = "pure",
        pins = {
            { name = "pos", kind = "data", direction = "in", dataType = "coord", default = { x = 0, y = 0 } },
        },
        run = function() end,
    })

    return registry
end

function TestSerialize:setUp()
    self.registry = buildRegistry()
    self.graph = Graph.new(self.registry)
end

function TestSerialize:testSerializeProducesJsonSafeShape()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local addId = self.graph:AddNode("fixture.add", { a = 2, b = 3 })
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(triggerId, "out", actionId, "in")
    self.graph:Connect(addId, "sum", actionId, "value")

    local data = Serialize.Serialize(self.graph)

    luaunit.assertEquals(data.version, 1)
    luaunit.assertEquals(#data.nodes, 3)
    luaunit.assertEquals(#data.connections, 2)

    local addNodeData
    for _, nodeData in ipairs(data.nodes) do
        if nodeData.type == "fixture.add" then
            addNodeData = nodeData
        end
    end
    luaunit.assertNotIsNil(addNodeData)
    luaunit.assertEquals(addNodeData.controls.a, 2)
    luaunit.assertEquals(addNodeData.controls.b, 3)
end

function TestSerialize:testDeserializeRebuildsEquivalentGraph()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local addId = self.graph:AddNode("fixture.add", { a = 2, b = 3 })
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(triggerId, "out", actionId, "in")
    self.graph:Connect(addId, "sum", actionId, "value")

    local data = Serialize.Serialize(self.graph)
    local rebuilt = Serialize.Deserialize(data, buildRegistry())

    luaunit.assertEquals(#rebuilt:GetNodes(), 3)
    luaunit.assertEquals(#rebuilt:GetConnections(), 2)

    local newAddId
    for _, node in ipairs(rebuilt:GetNodes()) do
        if node.typeKey == "fixture.add" then
            newAddId = node.id
        end
    end
    luaunit.assertEquals(rebuilt:GetControl(newAddId, "a"), 2)
    luaunit.assertEquals(rebuilt:GetControl(newAddId, "b"), 3)
end

function TestSerialize:testDeserializePreservesNodeIds()
    -- Build a graph with a gap in the id sequence (a removed node) so a naive
    -- "renumber from 1" deserialize would visibly differ from the original ids.
    local triggerId = self.graph:AddNode("fixture.trigger")
    local throwaway = self.graph:AddNode("fixture.add")
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:RemoveNode(throwaway)
    self.graph:Connect(triggerId, "out", actionId, "in")

    local data = Serialize.Serialize(self.graph)
    local rebuilt = Serialize.Deserialize(data, buildRegistry())

    -- Original ids survive the round-trip, so external id-keyed data stays valid.
    luaunit.assertNotIsNil(rebuilt.nodes[triggerId])
    luaunit.assertNotIsNil(rebuilt.nodes[actionId])
    luaunit.assertIsNil(rebuilt.nodes[throwaway])
    luaunit.assertEquals(rebuilt.nodes[triggerId].typeKey, "fixture.trigger")
    luaunit.assertEquals(rebuilt.nodes[actionId].typeKey, "fixture.action")

    -- A freshly added node lands above every restored id (no collision).
    local freshId = rebuilt:AddNode("fixture.add")
    luaunit.assertEquals(freshId, actionId + 1)
end

function TestSerialize:testExportImportJsonRoundTripPreservesBehavior()
    local log = {}
    local registry = buildRegistry()
    -- override fixture.action's run for this test so we can observe the pulled sum
    registry.nodeTypes["fixture.action"].run = function(ctx)
        log[#log + 1] = ctx:In("value")
    end

    local graph = Graph.new(registry)
    local triggerId = graph:AddNode("fixture.trigger")
    local addId = graph:AddNode("fixture.add", { a = 4, b = 5 })
    local actionId = graph:AddNode("fixture.action")
    graph:Connect(triggerId, "out", actionId, "in")
    graph:Connect(addId, "sum", actionId, "value")

    local exported = Serialize.ExportJSON(graph)
    luaunit.assertEquals(type(exported), "string")

    local registry2 = buildRegistry()
    registry2.nodeTypes["fixture.action"].run = function(ctx)
        log[#log + 1] = ctx:In("value")
    end
    local imported = Serialize.ImportJSON(exported, registry2)

    local triggerId2
    for _, node in ipairs(imported:GetNodes()) do
        if node.typeKey == "fixture.trigger" then
            triggerId2 = node.id
        end
    end
    imported:Fire(triggerId2)

    luaunit.assertEquals(#log, 1)
    luaunit.assertEquals(log[1], 9)
end

function TestSerialize:testDataTypeEncodeDecodeHooksAreApplied()
    local registry = buildRegistry()
    registry:RegisterDataType("coord", {
        encode = function(v) return v.x .. "," .. v.y end,
        decode = function(s)
            local x, y = s:match("(-?%d+),(-?%d+)")
            return { x = tonumber(x), y = tonumber(y) }
        end,
    })

    local graph = Graph.new(registry)
    local coordId = graph:AddNode("fixture.coord", { pos = { x = 7, y = -2 } })

    local data = Serialize.Serialize(graph)
    local encodedControl = data.nodes[1].controls.pos
    luaunit.assertEquals(encodedControl, "7,-2")

    local rebuilt = Serialize.Deserialize(data, registry)
    local rebuiltId = rebuilt:GetNodes()[1].id
    local pos = rebuilt:GetControl(rebuiltId, "pos")
    luaunit.assertEquals(pos.x, 7)
    luaunit.assertEquals(pos.y, -2)
end

function TestSerialize:testDeserializeRejectsUnknownNodeType()
    local data = {
        version = 1,
        nodes = { { id = 1, type = "fixture.nonexistent", controls = {} } },
        connections = {},
    }
    luaunit.assertErrorMsgContains("unknown node type", function()
        Serialize.Deserialize(data, self.registry)
    end)
end

function TestSerialize:testDeserializeRejectsConnectionToUnknownNodeId()
    local data = {
        version = 1,
        nodes = { { id = 1, type = "fixture.trigger", controls = {} } },
        connections = { { fromNode = 1, fromPin = "out", toNode = 999, toPin = "in" } },
    }
    luaunit.assertErrorMsgContains("unknown node id", function()
        Serialize.Deserialize(data, self.registry)
    end)
end

return TestSerialize
