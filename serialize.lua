-- Graph <-> plain-table <-> JSON conversion (docs/adr/0007). Serialize/Deserialize
-- work on a canonical, JSON-safe Lua table; ExportJSON/ImportJSON are thin wrappers
-- around that plus an injectable codec. LibNodeGraph never calls persistentdb itself
-- -- the consumer owns persistence and hands this the same string either way.

local Graph = require("graph")
local Json = require("json")
local Registry = require("registry")

-- Emitted through the client's `log` global when available (a lenient Deserialize dropping a
-- wire), and a no-op under the standalone test interpreter, which has no such global.
---@param msg string
local function warn(msg)
    if type(log) == "function" then
        log("[LibNodeGraph] " .. msg)
    end
end

---The flat, JSON-safe form of a graph — what a consumer persists or shares. Distinct from the
---live `LibNodeGraph.Graph`: it drops all runtime state (a node's `values`/`state`, the id
---counters), keys nothing by id (nodes/connections are ordered arrays so JSON stays clean), and
---encodes Control values through their Data Type codecs. Round-trips via Serialize/Deserialize.
---@class LibNodeGraph.SerializedNode
---@field id integer
---@field type string                     # the Node Type key (live Node calls this `typeKey`)
---@field controls table<string, any>     # codec-encoded Control values, keyed by pin name
---@field mode string|nil                 # instance mode key; omitted when the type has no modes
---@field name string|nil                 # optional node name; omitted when unset

---@class LibNodeGraph.SerializedConnection
---@field fromNode integer
---@field fromPin string
---@field toNode integer
---@field toPin string

---@class LibNodeGraph.SerializedGraph
---@field version integer                 # schema version, for future migrations
---@field nodes LibNodeGraph.SerializedNode[]
---@field connections LibNodeGraph.SerializedConnection[]

local Serialize = {}

local CURRENT_VERSION = 1

---@param graph LibNodeGraph.Graph
---@return LibNodeGraph.SerializedGraph
function Serialize.Serialize(graph)
    local registry = graph.registry

    local nodes = {}
    for _, node in pairs(graph.nodes) do
        if node.typeKey == Registry.UNKNOWN_TYPE and node.unknown ~= nil then
            -- A placeholder round-trips as its ORIGINAL type, raw controls, mode, and name,
            -- verbatim: the on-disk shape is exactly what was read, so a save with a
            -- still-missing type is byte-identical to the load (no schema bump, lossless
            -- while the type is absent).
            local record = { id = node.id, type = node.unknown.type, controls = node.unknown.controls }
            if node.unknown.mode ~= nil then
                record.mode = node.unknown.mode
            end
            if node.unknown.name ~= nil then
                record.name = node.unknown.name
            end
            nodes[#nodes + 1] = record
        else
            local nodeType = registry:GetNodeType(node.typeKey)
            local pins = Registry.pinSet(nodeType, node.mode)
            local controls = {}
            for pinName, value in pairs(node.controls) do
                local pin = pins and pins[pinName]
                local dataType = pin and registry:GetDataType(pin.dataType)
                if dataType ~= nil and dataType.encode ~= nil then
                    controls[pinName] = dataType.encode(value)
                else
                    controls[pinName] = value
                end
            end
            local record = { id = node.id, type = node.typeKey, controls = controls }
            if nodeType ~= nil and nodeType.modes ~= nil then
                record.mode = node.mode
            end
            if node.name ~= nil then
                record.name = node.name
            end
            nodes[#nodes + 1] = record
        end
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

---How a Deserialize handles a node whose `type` is not registered:
---  `"error"`       — assert (default; the strict, loud-canary contract other consumers rely on).
---  `"placeholder"` — preserve it as an inert `__unknown__` node stashing the original type + raw
---                    controls, mode, and name, so it round-trips losslessly and restores once the type returns.
---  `"skip"`        — drop the node and every wire touching it.
---In `"placeholder"` and `"skip"` mode Deserialize is TOTAL — it never throws: any connection it
---can't honor (missing node, missing pin, type mismatch, cycle, duplicate data input) is dropped
---and logged rather than raised.
---@alias LibNodeGraph.OnUnknown "error"|"placeholder"|"skip"

---@class LibNodeGraph.DeserializeOpts
---@field onUnknown? LibNodeGraph.OnUnknown  # default "error"

---@param data LibNodeGraph.SerializedGraph
---@param registry LibNodeGraph.Registry
---@param opts LibNodeGraph.DeserializeOpts|nil
---@return LibNodeGraph.Graph
function Serialize.Deserialize(data, registry, opts)
    assert(type(data) == "table", "Deserialize requires a table")
    opts = opts or {}
    local onUnknown = opts.onUnknown or "error"
    assert(onUnknown == "error" or onUnknown == "placeholder" or onUnknown == "skip",
        "Deserialize opts.onUnknown must be 'error', 'placeholder', or 'skip'")
    local lenient = onUnknown ~= "error"

    local graph = Graph.new(registry)
    local maxId = 0

    for _, nodeData in ipairs(data.nodes or {}) do
        local nodeType = registry:GetNodeType(nodeData.type)

        if nodeData.id > maxId then maxId = nodeData.id end

        if nodeType == nil then
            -- Unknown type. In "error" mode this is the historical loud failure. In "skip" mode
            -- the node is simply absent (its wires get dropped in the connection loop below). In
            -- "placeholder" mode it becomes an inert `__unknown__` node carrying the originals.
            assert(lenient, "unknown node type '" .. tostring(nodeData.type) .. "' during deserialize")
            if onUnknown == "placeholder" then
                graph.nextNodeId = nodeData.id
                local newId = graph:AddNode(Registry.UNKNOWN_TYPE, {})
                assert(newId == nodeData.id, "failed to preserve node id during deserialize")
                -- Stash the original type + raw controls, mode, and name verbatim so Serialize
                -- re-emits them unchanged (lossless round-trip). The live controls stay empty —
                -- the placeholder type has no pins.
                graph.nodes[newId].unknown = {
                    type = nodeData.type,
                    controls = nodeData.controls or {},
                    mode = nodeData.mode,
                    name = nodeData.name,
                }
            else
                warn("skipping unknown node type '" .. tostring(nodeData.type) .. "' (id " .. tostring(nodeData.id) .. ")")
            end
        else
            local modeKey = nodeData.mode
            if nodeType.modes ~= nil then
                if modeKey == nil or nodeType.modes[modeKey] == nil then
                    modeKey = nodeType.defaultMode
                end
            else
                modeKey = nil
            end
            local pins = Registry.pinSet(nodeType, modeKey)
            local controls = {}
            for pinName, value in pairs(nodeData.controls or {}) do
                local pin = pins and pins[pinName]
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
            local newId = graph:AddNode(nodeData.type, controls, modeKey)
            assert(newId == nodeData.id, "failed to preserve node id during deserialize")
            if nodeData.name ~= nil then
                graph.nodes[newId].name = nodeData.name
            end
        end
    end
    -- Keep allocating ids above every restored one so a later AddNode can't collide (also
    -- guards ids of skipped nodes, whose slot is intentionally left empty).
    graph.nextNodeId = maxId + 1

    for _, connData in ipairs(data.connections or {}) do
        local fromNode = graph.nodes[connData.fromNode]
        local toNode = graph.nodes[connData.toNode]

        if fromNode == nil or toNode == nil then
            -- An endpoint is gone (unknown id, or a "skip"-dropped node). Strict mode keeps the
            -- historical assert; lenient mode drops the wire and moves on (totality invariant).
            assert(lenient, "connection references unknown node id during deserialize")
            warn("dropping connection to missing node ("
                .. tostring(connData.fromNode) .. " -> " .. tostring(connData.toNode) .. ")")
        elseif fromNode.typeKey == Registry.UNKNOWN_TYPE or toNode.typeKey == Registry.UNKNOWN_TYPE then
            -- A placeholder has no pins, so the validated Connect could never accept this wire;
            -- insert it raw so it survives verbatim and restores when the real type returns.
            -- Placeholders only exist in lenient mode, so this path never runs under "error".
            graph:_insertRawConnection(connData)
        elseif not lenient then
            -- Connect reports a rejection reason rather than throwing (uniform result contract);
            -- strict mode still fails the load loudly on any bad wire.
            local id, reason = graph:Connect(
                connData.fromNode, connData.fromPin, connData.toNode, connData.toPin)
            assert(id ~= nil, "connection rejected during deserialize: " .. tostring(reason))
        else
            -- Known <-> known in lenient mode: honor each wire independently. A wire the graph
            -- rejects (missing pin, type mismatch, cycle, duplicate/occupied data input in a
            -- corrupt save) is dropped and logged rather than taking down the whole load.
            local id, reason = graph:Connect(
                connData.fromNode, connData.fromPin, connData.toNode, connData.toPin)
            if id == nil then
                warn("dropping invalid connection "
                    .. tostring(connData.fromNode) .. ":" .. tostring(connData.fromPin) .. " -> "
                    .. tostring(connData.toNode) .. ":" .. tostring(connData.toPin)
                    .. " (" .. tostring(reason) .. ")")
            end
        end
    end

    return graph
end

function Serialize.ExportJSON(graph, codec)
    codec = codec or Json.Default
    return codec.encode(Serialize.Serialize(graph))
end

function Serialize.ImportJSON(text, registry, codec, opts)
    codec = codec or Json.Default
    return Serialize.Deserialize(codec.decode(text), registry, opts)
end

return Serialize
