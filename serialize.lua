-- Graph <-> plain-table <-> JSON conversion (docs/adr/0007). Serialize/Deserialize
-- work on a canonical, JSON-safe Lua table; ExportJSON/ImportJSON are thin wrappers
-- around that plus an injectable codec. LibNodeGraph never calls persistentdb itself
-- -- the consumer owns persistence and hands this the same string either way.

local Graph = require("graph")
local Json = require("json")

local Serialize = {}

local CURRENT_VERSION = 1

function Serialize.Serialize(graph)
    local registry = graph.registry

    local nodes = {}
    for _, node in pairs(graph.nodes) do
        local nodeType = registry:GetNodeType(node.typeKey)
        local controls = {}
        for pinName, value in pairs(node.controls) do
            local pin = nodeType and nodeType.pins[pinName]
            local dataType = pin and registry:GetDataType(pin.dataType)
            if dataType ~= nil and dataType.encode ~= nil then
                controls[pinName] = dataType.encode(value)
            else
                controls[pinName] = value
            end
        end
        nodes[#nodes + 1] = { id = node.id, type = node.typeKey, controls = controls }
    end
    table.sort(nodes, function(a, b)
        return a.id < b.id
    end)

    local connections = {}
    for _, conn in pairs(graph.connections) do
        connections[#connections + 1] = {
            fromNode = conn.fromNode,
            fromPin = conn.fromPin,
            toNode = conn.toNode,
            toPin = conn.toPin,
        }
    end
    table.sort(connections, function(a, b)
        if a.fromNode ~= b.fromNode then
            return a.fromNode < b.fromNode
        end
        return a.fromPin < b.fromPin
    end)

    return {
        version = CURRENT_VERSION,
        nodes = nodes,
        connections = connections,
    }
end

function Serialize.Deserialize(data, registry)
    assert(type(data) == "table", "Deserialize requires a table")

    local graph = Graph.new(registry)
    local maxId = 0

    for _, nodeData in ipairs(data.nodes or {}) do
        local nodeType = registry:GetNodeType(nodeData.type)
        assert(nodeType ~= nil, "unknown node type '" .. tostring(nodeData.type) .. "' during deserialize")

        local controls = {}
        for pinName, value in pairs(nodeData.controls or {}) do
            local pin = nodeType.pins[pinName]
            local dataType = pin and registry:GetDataType(pin.dataType)
            if dataType ~= nil and dataType.decode ~= nil then
                controls[pinName] = dataType.decode(value)
            else
                controls[pinName] = value
            end
        end

        -- Preserve the original node id (a lossless round-trip), not just the graph's
        -- shape, so external id-keyed data a consumer holds alongside the graph — e.g.
        -- Watchdog's Layout (nodeId -> position) — stays valid across a save/load.
        -- AddNode draws the new id from graph.nextNodeId, so pin it to the stored id.
        graph.nextNodeId = nodeData.id
        local newId = graph:AddNode(nodeData.type, controls)
        assert(newId == nodeData.id, "failed to preserve node id during deserialize")
        if nodeData.id > maxId then maxId = nodeData.id end
    end
    -- Keep allocating ids above every restored one so a later AddNode can't collide.
    graph.nextNodeId = maxId + 1

    for _, connData in ipairs(data.connections or {}) do
        assert(graph.nodes[connData.fromNode] ~= nil and graph.nodes[connData.toNode] ~= nil,
            "connection references unknown node id during deserialize")
        graph:Connect(connData.fromNode, connData.fromPin, connData.toNode, connData.toPin)
    end

    return graph
end

function Serialize.ExportJSON(graph, codec)
    codec = codec or Json.Default
    return codec.encode(Serialize.Serialize(graph))
end

function Serialize.ImportJSON(text, registry, codec)
    codec = codec or Json.Default
    return Serialize.Deserialize(codec.decode(text), registry)
end

return Serialize
