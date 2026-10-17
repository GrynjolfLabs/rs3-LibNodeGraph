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

--- Unknown-node preservation (issue #1) --------------------------------------------------

function TestSerialize:testPlaceholderRoundTripIsLossless()
    -- fixture.ghost is not in buildRegistry(), so it deserializes as a placeholder. Serializing
    -- the result must reproduce the ON-DISK form byte-for-byte (the canonical table, key-order
    -- independent): original type key and raw controls re-emitted verbatim, wire intact.
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.ghost", controls = { foo = "bar", n = 3 } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })
    luaunit.assertEquals(graph.nodes[2].typeKey, "__unknown__")

    local reserialized = Serialize.Serialize(graph)
    luaunit.assertEquals(reserialized, data)
end

function TestSerialize:testKnownToUnknownWireSurvivesAsLiveConnection()
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.ghost", controls = {} },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })
    local conns = graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].fromNode, 1)
    luaunit.assertEquals(conns[1].toNode, 2)
    luaunit.assertEquals(graph.nodes[2].typeKey, "__unknown__")
end

function TestSerialize:testPlaceholderIsInertWhenFiredInto()
    -- A known upstream trigger firing into the placeholder must dead-end there (no throw).
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.ghost", controls = {} },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })
    graph:Fire(1)  -- must not throw

    -- The placeholder was reached (executed) but fired nothing onward.
    local sawPlaceholderExecute, sawFireFromPlaceholder = false, false
    for _, entry in ipairs(graph:GetLastTrace()) do
        if entry.type == "execute" and entry.node == 2 then sawPlaceholderExecute = true end
        if entry.type == "fire" and entry.node == 2 then sawFireFromPlaceholder = true end
    end
    luaunit.assertIsTrue(sawPlaceholderExecute)
    luaunit.assertIsFalse(sawFireFromPlaceholder)
end

function TestSerialize:testPullingFromPlaceholderYieldsNil()
    local reg = buildRegistry()
    local ran = false
    local pulled = "SENTINEL"
    reg.nodeTypes["fixture.action"].run = function(ctx)
        ran = true
        pulled = ctx:In("value")
    end

    -- The placeholder feeds action.value; even though the control is 7, the incoming wire wins
    -- and pulls from the inert placeholder -> nil, without throwing.
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.ghost", controls = {} },
            { id = 2, type = "fixture.action", controls = { value = 7 } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "value" },
        },
    }

    local graph = Serialize.Deserialize(data, reg, { onUnknown = "placeholder" })
    graph:FireInput(2, "in")

    luaunit.assertIsTrue(ran)
    luaunit.assertIsNil(pulled)
end

function TestSerialize:testPlaceholderRestoresToRealNodeWhenTypeReturns()
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.ghost", controls = { tag = 7 } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },
        },
    }

    -- Load while missing -> placeholder, then re-save (still lossless).
    local missing = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })
    local saved = Serialize.Serialize(missing)

    -- The type comes back: an ordinary (default, strict) deserialize rebuilds the real node.
    local reg = buildRegistry()
    reg:RegisterNodeType("fixture.ghost", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "tag", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function() end,
    })
    local restored = Serialize.Deserialize(saved, reg)

    luaunit.assertEquals(restored.nodes[2].typeKey, "fixture.ghost")
    luaunit.assertEquals(restored:GetControl(2, "tag"), 7)
    luaunit.assertEquals(#restored:GetConnections(), 1)
end

function TestSerialize:testLenientDeserializeIsTotal()
    -- (a) an unknown type, (b) a wire to a missing pin on a known node, (c) a kind-mismatched
    -- wire between known nodes. Placeholder mode must deserialize all three without throwing;
    -- (b) and (c) are dropped, the placeholder wire (a) is kept.
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.ghost", controls = {} },
            { id = 3, type = "fixture.add", controls = { a = 1, b = 2 } },
            { id = 4, type = "fixture.action", controls = {} },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },           -- known -> placeholder
            { fromNode = 1, fromPin = "out", toNode = 4, toPin = "nonexistent" },  -- (b) missing pin
            { fromNode = 3, fromPin = "sum", toNode = 4, toPin = "in" },           -- (c) data -> exec
        },
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })

    local conns = graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].toNode, 2)
end

function TestSerialize:testSkipModeDropsUnknownNodeAndItsWires()
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 2, type = "fixture.ghost", controls = {} },     -- unknown -> dropped
            { id = 3, type = "fixture.action", controls = {} },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 2, toPin = "in" },  -- touches dropped node
            { fromNode = 1, fromPin = "out", toNode = 3, toPin = "in" },  -- known -> known, kept
        },
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "skip" })

    luaunit.assertIsNil(graph.nodes[2])
    luaunit.assertNotIsNil(graph.nodes[1])
    luaunit.assertNotIsNil(graph.nodes[3])

    local conns = graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].toNode, 3)

    -- A dropped node's id is still reserved, so a fresh AddNode can't collide with it.
    local fresh = graph:AddNode("fixture.add")
    luaunit.assertEquals(fresh, 4)
end

function TestSerialize:testInvalidOnUnknownOptionRejected()
    luaunit.assertErrorMsgContains("onUnknown", function()
        Serialize.Deserialize({ version = 1, nodes = {}, connections = {} },
            self.registry, { onUnknown = "bogus" })
    end)
end

--- Optional node name (issue #2) ---------------------------------------------------------

function TestSerialize:testSerializeOmitsNameWhenUnset()
    local id = self.graph:AddNode("fixture.trigger")
    luaunit.assertIsNil(self.graph.nodes[id].name)

    local data = Serialize.Serialize(self.graph)
    luaunit.assertEquals(data.nodes[1].id, id)
    luaunit.assertEquals(data.nodes[1].type, "fixture.trigger")
    luaunit.assertIsNil(data.nodes[1].name)
end

function TestSerialize:testSerializeRoundTripsName()
    local id = self.graph:AddNode("fixture.trigger")
    self.graph.nodes[id].name = "Enrage callout"

    local data = Serialize.Serialize(self.graph)
    luaunit.assertEquals(data.version, 1)
    luaunit.assertEquals(data.nodes[1].id, id)
    luaunit.assertEquals(data.nodes[1].type, "fixture.trigger")
    luaunit.assertEquals(data.nodes[1].name, "Enrage callout")

    local restored = Serialize.Deserialize(data, buildRegistry())
    luaunit.assertEquals(restored.nodes[id].name, "Enrage callout")
    luaunit.assertEquals(restored.nodes[id].typeKey, "fixture.trigger")
end

function TestSerialize:testClearingNameOmitsItAgain()
    local id = self.graph:AddNode("fixture.add", { a = 2, b = 3 })
    self.graph.nodes[id].name = "Enrage callout"

    local named = Serialize.Serialize(self.graph)
    luaunit.assertEquals(named.nodes[1].name, "Enrage callout")

    self.graph.nodes[id].name = nil
    local cleared = Serialize.Serialize(self.graph)
    luaunit.assertEquals(cleared.nodes[1].id, id)
    luaunit.assertEquals(cleared.nodes[1].type, "fixture.add")
    luaunit.assertEquals(cleared.nodes[1].controls.a, 2)
    luaunit.assertEquals(cleared.nodes[1].controls.b, 3)
    luaunit.assertIsNil(cleared.nodes[1].name)
end

function TestSerialize:testPlaceholderReemitsNameWithOriginalTypeControlsAndMode()
    local data = {
        version = 1,
        nodes = {
            {
                id = 1,
                type = "fixture.ghost",
                controls = { foo = "bar", n = 3 },
                mode = "loud",
                name = "Enrage callout",
            },
        },
        connections = {},
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })
    luaunit.assertEquals(graph.nodes[1].typeKey, "__unknown__")

    local reserialized = Serialize.Serialize(graph)
    luaunit.assertEquals(reserialized, data)
end

function TestSerialize:testPlaceholderWithoutNameOmitsIt()
    local data = {
        version = 1,
        nodes = {
            {
                id = 1,
                type = "fixture.ghost",
                controls = { foo = "bar", n = 3 },
                mode = "loud",
            },
        },
        connections = {},
    }

    local graph = Serialize.Deserialize(data, buildRegistry(), { onUnknown = "placeholder" })
    luaunit.assertEquals(graph.nodes[1].typeKey, "__unknown__")

    local reserialized = Serialize.Serialize(graph)
    luaunit.assertEquals(reserialized, data)
    luaunit.assertIsNil(reserialized.nodes[1].name)
end

function TestSerialize:testDeserializeLoadsGraphWithNoNameField()
    local data = {
        version = 1,
        nodes = {
            { id = 1, type = "fixture.trigger", controls = {} },
            { id = 3, type = "fixture.action", controls = { value = 7 } },
        },
        connections = {
            { fromNode = 1, fromPin = "out", toNode = 3, toPin = "in" },
        },
    }

    local graph = Serialize.Deserialize(data, buildRegistry())
    luaunit.assertEquals(graph.nodes[1].typeKey, "fixture.trigger")
    luaunit.assertIsNil(graph.nodes[1].name)
    luaunit.assertEquals(graph.nodes[3].typeKey, "fixture.action")
    luaunit.assertIsNil(graph.nodes[3].name)
    luaunit.assertEquals(graph:GetControl(3, "value"), 7)
    luaunit.assertEquals(#graph:GetConnections(), 1)
    luaunit.assertEquals(graph:GetConnections()[1].fromNode, 1)
    luaunit.assertEquals(graph:GetConnections()[1].toNode, 3)

    local saved = Serialize.Serialize(graph)
    luaunit.assertEquals(saved, data)
    luaunit.assertIsNil(saved.nodes[1].name)
    luaunit.assertIsNil(saved.nodes[2].name)
end

return TestSerialize
