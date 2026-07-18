-- `Graph.__index = Graph` is set inside Graph.new, NOT at the top level: a self-referential
-- module table triggers an infinite traversal in the client at require time (freeze+crash).

---A single node instance living in a Graph. Runtime-only fields (`values`, `state`) are never
---serialized (see serialize.lua); only `id`, `typeKey`, and `controls` round-trip.
---@class LibNodeGraph.Node
---@field id integer                      # stable, unique within its Graph; assigned by AddNode
---@field typeKey string                  # the registered Node Type key (see Registry)
---@field controls table<string, any>     # per-data-input Control values, keyed by pin name
---@field values table<string, any>       # last computed output value per pin; runtime-only
---@field state table                     # per-node persistent scratch (ctx.state); runtime-only
---@field unknown? { type: string, controls: table<string, any> }  # set only on a `__unknown__` placeholder: the original type key + raw (codec-encoded) controls, re-emitted verbatim by Serialize

---A directed edge between two pins. Connects an output pin (`from*`) to an input pin (`to*`);
---exec pins carry flow, data pins carry values. See Graph:Connect for the validity rules.
---@class LibNodeGraph.Connection
---@field id integer                      # stable, unique within its Graph
---@field fromNode integer                # source node id
---@field fromPin string                  # source (output) pin name
---@field toNode integer                  # target node id
---@field toPin string                    # target (input) pin name

---The live, mutable graph: the authored node network plus the bookkeeping to run it. This is
---the in-memory object the editor and runtime operate on — distinct from the flat, persistable
---`LibNodeGraph.SerializedGraph` that Serialize/Deserialize convert to and from.
---@class LibNodeGraph.Graph
---@field registry LibNodeGraph.Registry           # the Node Type registry this graph resolves against
---@field nodes table<integer, LibNodeGraph.Node>  # all nodes, keyed by node id
---@field connections table<integer, LibNodeGraph.Connection>  # all edges, keyed by connection id
---@field nextNodeId integer              # id handed to the next AddNode
---@field nextConnectionId integer        # id handed to the next Connect
---@field lastTrace table                 # exec path of the most recent Fire, for debugging
local Graph = {}

-- Backstop against engine bugs; graphs are cycle-checked at connect-time so this
-- should never be hit in practice (see docs/adr/0004-execution-semantics.md).
local MAX_DEPTH = 256

local function hasExecPins(nodeType)
    for _, pinName in ipairs(nodeType.pinOrder) do
        if nodeType.pins[pinName].kind == "exec" then
            return true
        end
    end
    return false
end

local function copyDefault(value)
    if type(value) == "table" then
        local copy = {}
        for k, v in pairs(value) do
            copy[k] = v
        end
        return copy
    end
    return value
end

---@param registry LibNodeGraph.Registry
---@return LibNodeGraph.Graph
function Graph.new(registry)
    Graph.__index = Graph
    assert(registry ~= nil, "Graph.new requires a Registry")
    return setmetatable({
        registry = registry,
        nodes = {},
        connections = {},
        nextNodeId = 1,
        nextConnectionId = 1,
        lastTrace = {},
        _activeTrace = nil,
    }, Graph)
end

--- Structure: nodes, connections ---------------------------------------------------

---@param typeKey string                  # a registered Node Type key
---@param controls table<string, any>|nil # optional initial Control values, keyed by pin name
---@return integer id                      # the new node's stable id
function Graph:AddNode(typeKey, controls)
    local nodeType = self.registry:GetNodeType(typeKey)
    assert(nodeType ~= nil, "unknown node type '" .. tostring(typeKey) .. "'")

    local id = self.nextNodeId
    self.nextNodeId = id + 1

    local nodeControls = {}
    for _, pinName in ipairs(nodeType.pinOrder) do
        local pin = nodeType.pins[pinName]
        if pin.kind == "data" and pin.direction == "in" then
            if controls ~= nil and controls[pinName] ~= nil then
                nodeControls[pinName] = controls[pinName]
            else
                nodeControls[pinName] = copyDefault(pin.default)
            end
        end
    end

    self.nodes[id] = {
        id = id,
        typeKey = typeKey,
        controls = nodeControls,
        values = {},
        -- Per-node persistent scratch, exposed to run as ctx.state. Survives across
        -- Fires like `values`, and like `values` is runtime-only (never serialized).
        -- See docs/adr/0010-stateful-node-support.md.
        state = {},
    }
    return id
end

function Graph:RemoveNode(id)
    if self.nodes[id] == nil then
        return
    end
    self.nodes[id] = nil
    for connId, conn in pairs(self.connections) do
        if conn.fromNode == id or conn.toNode == id then
            self.connections[connId] = nil
        end
    end
end

function Graph:_getPin(nodeId, pinName)
    local node = self.nodes[nodeId]
    if node == nil then
        return nil
    end
    local nodeType = self.registry:GetNodeType(node.typeKey)
    if nodeType == nil then
        return nil
    end
    return nodeType.pins[pinName]
end

--- Cycle detection (docs/adr/0004, rule 4) ------------------------------------------

-- Builds the propagation graph: inter-node edges (existing wires) plus intra-node
-- edges (non-Terminator exec input -> every exec output of the same node; and,
-- conservatively, every data input -> every data output of the same node, since a
-- Pure Node's run may read any of its inputs to produce any of its outputs).
function Graph:_buildPropagationEdges()
    local edges = {}

    local function addEdge(fromKey, toKey)
        local list = edges[fromKey]
        if list == nil then
            list = {}
            edges[fromKey] = list
        end
        list[#list + 1] = toKey
    end

    for _, conn in pairs(self.connections) do
        addEdge(conn.fromNode .. ":" .. conn.fromPin, conn.toNode .. ":" .. conn.toPin)
    end

    for nodeId, node in pairs(self.nodes) do
        local nodeType = self.registry:GetNodeType(node.typeKey)
        if nodeType ~= nil then
            local execOutputs, execInputs, dataOutputs, dataInputs = {}, {}, {}, {}
            for _, pinName in ipairs(nodeType.pinOrder) do
                local pin = nodeType.pins[pinName]
                if pin.kind == "exec" and pin.direction == "out" then
                    execOutputs[#execOutputs + 1] = pinName
                elseif pin.kind == "exec" and pin.direction == "in" and not pin.terminates then
                    execInputs[#execInputs + 1] = pinName
                elseif pin.kind == "data" and pin.direction == "out" then
                    dataOutputs[#dataOutputs + 1] = pinName
                elseif pin.kind == "data" and pin.direction == "in" then
                    dataInputs[#dataInputs + 1] = pinName
                end
            end
            for _, inputName in ipairs(execInputs) do
                for _, outputName in ipairs(execOutputs) do
                    addEdge(nodeId .. ":" .. inputName, nodeId .. ":" .. outputName)
                end
            end
            for _, inputName in ipairs(dataInputs) do
                for _, outputName in ipairs(dataOutputs) do
                    addEdge(nodeId .. ":" .. inputName, nodeId .. ":" .. outputName)
                end
            end
        end
    end

    return edges
end

function Graph:_canReach(edges, startKey, targetKey)
    if startKey == targetKey then
        return true
    end
    local visited = { [startKey] = true }
    local stack = { startKey }
    while #stack > 0 do
        local current = table.remove(stack)
        for _, nextKey in ipairs(edges[current] or {}) do
            if nextKey == targetKey then
                return true
            end
            if not visited[nextKey] then
                visited[nextKey] = true
                stack[#stack + 1] = nextKey
            end
        end
    end
    return false
end

--- Connections -----------------------------------------------------------------------

function Graph:Connect(fromNode, fromPin, toNode, toPin)
    local fromPinDef = self:_getPin(fromNode, fromPin)
    local toPinDef = self:_getPin(toNode, toPin)
    assert(fromPinDef ~= nil, "unknown pin '" .. tostring(fromPin) .. "' on node " .. tostring(fromNode))
    assert(toPinDef ~= nil, "unknown pin '" .. tostring(toPin) .. "' on node " .. tostring(toNode))
    assert(fromPinDef.direction == "out", "'" .. fromPin .. "' is not an output pin")
    assert(toPinDef.direction == "in", "'" .. toPin .. "' is not an input pin")
    assert(fromPinDef.kind == toPinDef.kind, "cannot connect an exec pin to a data pin")

    if fromPinDef.kind == "data" then
        local fromTag, toTag = fromPinDef.dataType, toPinDef.dataType
        assert(fromTag == toTag or fromTag == "any" or toTag == "any",
            "data type mismatch: '" .. tostring(fromTag) .. "' -> '" .. tostring(toTag) .. "'")
        for _, conn in pairs(self.connections) do
            assert(not (conn.toNode == toNode and conn.toPin == toPin),
                "data input '" .. toPin .. "' on node " .. tostring(toNode) .. " already has a connection")
        end
    end

    local fromKey, toKey = fromNode .. ":" .. fromPin, toNode .. ":" .. toPin
    local edges = self:_buildPropagationEdges()
    assert(not self:_canReach(edges, toKey, fromKey),
        "connecting '" .. fromPin .. "' -> '" .. toPin .. "' would create a cycle")

    local id = self.nextConnectionId
    self.nextConnectionId = id + 1
    self.connections[id] = {
        id = id,
        fromNode = fromNode,
        fromPin = fromPin,
        toNode = toNode,
        toPin = toPin,
    }
    return id
end

function Graph:Disconnect(connectionId)
    self.connections[connectionId] = nil
end

-- Unchecked connection insert, bypassing every rule Connect enforces (pin existence, direction,
-- kind/type match, single-data-input, cycle). Used only by a lenient Deserialize to restore a
-- wire that touches a `__unknown__` placeholder: the placeholder has no pins, so the validated
-- Connect path could never accept the wire, yet the wire must survive verbatim to round-trip
-- losslessly once the real type returns. Not for general use — a hand-built graph should always
-- go through Connect.
---@param record { fromNode: integer, fromPin: string, toNode: integer, toPin: string }
---@return integer id
function Graph:_insertRawConnection(record)
    local id = self.nextConnectionId
    self.nextConnectionId = id + 1
    self.connections[id] = {
        id = id,
        fromNode = record.fromNode,
        fromPin = record.fromPin,
        toNode = record.toNode,
        toPin = record.toPin,
    }
    return id
end

function Graph:_findSourceConnection(nodeId, pinName)
    for _, conn in pairs(self.connections) do
        if conn.toNode == nodeId and conn.toPin == pinName then
            return conn
        end
    end
    return nil
end

function Graph:_findTargetConnections(nodeId, pinName)
    local out = {}
    for _, conn in pairs(self.connections) do
        if conn.fromNode == nodeId and conn.fromPin == pinName then
            out[#out + 1] = conn
        end
    end
    return out
end

--- Controls ----------------------------------------------------------------------------

function Graph:SetControl(nodeId, pinName, value)
    local node = self.nodes[nodeId]
    assert(node ~= nil, "unknown node " .. tostring(nodeId))
    local pin = self:_getPin(nodeId, pinName)
    assert(pin ~= nil and pin.kind == "data" and pin.direction == "in",
        "'" .. tostring(pinName) .. "' is not a data input pin")
    node.controls[pinName] = value
end

---@return any  # the Control's current value (arbitrary — a scalar, a {x,y}, etc.); nil if no such node
function Graph:GetControl(nodeId, pinName)
    local node = self.nodes[nodeId]
    if node == nil then
        return nil
    end
    return node.controls[pinName]
end

function Graph:GetLastValue(nodeId, pinName)
    local node = self.nodes[nodeId]
    if node == nil then
        return nil
    end
    return node.values[pinName]
end

--- Read-only inspection (docs/adr/0006) -------------------------------------------------

---A lightweight projection — id + type only, NOT the full LibNodeGraph.Node (Controls/values/
---state are deliberately withheld; mutate through the Graph methods, not this snapshot).
---@return { id: integer, typeKey: string }[]
function Graph:GetNodes()
    local out = {}
    for _, node in pairs(self.nodes) do
        out[#out + 1] = { id = node.id, typeKey = node.typeKey }
    end
    return out
end

function Graph:GetNodesByCategory(category)
    local out = {}
    for _, node in pairs(self.nodes) do
        local nodeType = self.registry:GetNodeType(node.typeKey)
        if nodeType ~= nil and nodeType.category == category then
            out[#out + 1] = { id = node.id, typeKey = node.typeKey }
        end
    end
    return out
end

---@return LibNodeGraph.Connection[]
function Graph:GetConnections()
    local out = {}
    for _, conn in pairs(self.connections) do
        out[#out + 1] = {
            id = conn.id,
            fromNode = conn.fromNode,
            fromPin = conn.fromPin,
            toNode = conn.toNode,
            toPin = conn.toPin,
        }
    end
    return out
end

function Graph:GetPins(nodeId)
    local node = self.nodes[nodeId]
    if node == nil then
        return nil
    end
    local nodeType = self.registry:GetNodeType(node.typeKey)
    if nodeType == nil then
        return nil
    end
    local out = {}
    for _, pinName in ipairs(nodeType.pinOrder) do
        local pin = nodeType.pins[pinName]
        out[#out + 1] = {
            name = pin.name,
            kind = pin.kind,
            direction = pin.direction,
            dataType = pin.dataType,
            terminates = pin.terminates,
            label = pin.label,
            default = pin.default,
        }
    end
    return out
end

function Graph:GetLastTrace()
    return self.lastTrace
end

--- Execution (docs/adr/0003, docs/adr/0004) ---------------------------------------------

function Graph:_recordTrace(kind, nodeId, pinName, value)
    local trace = self._activeTrace
    if trace ~= nil then
        trace[#trace + 1] = { type = kind, node = nodeId, pin = pinName, value = value }
    end
end

-- The complete contract for the single argument every Node Type's `run` receives. This class
-- is the ONE authoritative shape of the run context; the field guard below and `_makeCtx`'s
-- construction are kept in lockstep with it, and every `run = function(ctx)` in a consumer is
-- typed against it (see registry.lua's NodeTypeDef.run) so a stray field read (e.g. `ctx.pin`
-- instead of `ctx.exec`) is a static undefined-field error rather than a silent nil.
---@class LibNodeGraph.RunContext
---@field nodeId integer                 # this node's own stable id
---@field payload any                    # event data on a Trigger entry; nil downstream (ADR-0009)
---@field exec string|nil                # which exec input fired; nil for Triggers / pulled Pure Nodes (ADR-0010)
---@field state table                    # per-node scratch, persists across Fires; not serialized
---@field In fun(self: LibNodeGraph.RunContext, pin: string): any  # pull a data input
---@field Out fun(self: LibNodeGraph.RunContext, pin: string, value: any)  # set a data output
---@field Fire fun(self: LibNodeGraph.RunContext, pin: string)  # continue through an exec output

-- Dynamic backstop to the static RunContext class: reading any field NOT on the contract
-- raises, so a node that references a field the engine never sets — a typo, or a plausible-but-
-- nonexistent field an author assumed — fails loudly the first time it's touched, in tests and
-- in dev, instead of silently evaluating to nil. Declared-but-absent fields stay legal: `exec`
-- is nil on a Trigger entry and `payload` is nil downstream, so those keys are simply missing
-- from the table — the allowlist lets a miss on them return nil, and only unknown names error.
local CTX_FIELDS = {
    nodeId = true, payload = true, exec = true, state = true,
    In = true, Out = true, Fire = true,
}
local CTX_GUARD = {
    __index = function(_, key)
        if CTX_FIELDS[key] then return nil end
        error("run(ctx): unknown ctx field '" .. tostring(key)
            .. "' — see the LibNodeGraph.RunContext contract in graph.lua", 2)
    end,
}

-- `payload` is the value handed to Graph:Fire, surfaced only on the entry node's ctx
-- (docs/adr/0009). `execPin` is the name of the exec input this run entered through,
-- or nil for an external entry / a pulled Pure Node (docs/adr/0010).
---@return LibNodeGraph.RunContext
function Graph:_makeCtx(node, nodeType, depth, payload, execPin)
    local graph = self
    return setmetatable({
        -- This node's own stable id, so a run can key external state (effect stacks, info
        -- boxes) to the specific node it belongs to rather than the node type.
        nodeId = node.id,
        -- Event data injected from outside at the Trigger; nil everywhere downstream.
        payload = payload,
        -- Which exec input fired this run; nil for Triggers and pulled Pure Nodes.
        exec = execPin,
        -- Per-node persistent state bag (survives across Fires; not serialized).
        state = node.state,
        In = function(_, pinName)
            return graph:_pull(node, pinName, depth)
        end,
        Out = function(_, pinName, value)
            local pin = nodeType.pins[pinName]
            assert(pin ~= nil and pin.kind == "data" and pin.direction == "out",
                "'" .. tostring(pinName) .. "' is not a data output pin on '" .. nodeType.key .. "'")
            node.values[pinName] = value
        end,
        Fire = function(_, pinName)
            graph:_fireOutput(node, pinName, depth)
        end,
    }, CTX_GUARD)
end

function Graph:_pull(node, pinName, depth)
    local nodeType = self.registry:GetNodeType(node.typeKey)
    local pin = nodeType.pins[pinName]
    assert(pin ~= nil and pin.kind == "data" and pin.direction == "in",
        "'" .. tostring(pinName) .. "' is not a data input pin on '" .. nodeType.key .. "'")

    local sourceConn = self:_findSourceConnection(node.id, pinName)
    if sourceConn == nil then
        return node.controls[pinName]
    end

    local sourceNode = self.nodes[sourceConn.fromNode]
    assert(sourceNode ~= nil, "dangling connection to missing node " .. tostring(sourceConn.fromNode))
    local sourceType = self.registry:GetNodeType(sourceNode.typeKey)

    if hasExecPins(sourceType) then
        -- Execution node: value only meaningful once it has run this Fire (rule 3).
        local value = sourceNode.values[sourceConn.fromPin]
        self:_recordTrace("pull", sourceNode.id, sourceConn.fromPin, value)
        return value
    end

    -- Pure Node: re-evaluate fresh on every pull (rule 3), no memoization.
    assert(depth < MAX_DEPTH, "recursion depth exceeded while pulling '" .. pinName .. "'")
    -- A pulled Pure Node has no payload and no entering exec pin.
    self:_executeNode(sourceNode, sourceType, depth + 1, nil, nil)
    local value = sourceNode.values[sourceConn.fromPin]
    self:_recordTrace("pull", sourceNode.id, sourceConn.fromPin, value)
    return value
end

function Graph:_executeNode(node, nodeType, depth, payload, execPin)
    self:_recordTrace("execute", node.id, nil, nil)
    local ctx = self:_makeCtx(node, nodeType, depth, payload, execPin)
    nodeType.run(ctx)
end

function Graph:_fireOutput(node, pinName, depth)
    local nodeType = self.registry:GetNodeType(node.typeKey)
    local pin = nodeType.pins[pinName]
    assert(pin ~= nil and pin.kind == "exec" and pin.direction == "out",
        "'" .. tostring(pinName) .. "' is not an exec output pin on '" .. nodeType.key .. "'")

    self:_recordTrace("fire", node.id, pinName, nil)
    assert(depth < MAX_DEPTH, "recursion depth exceeded while firing '" .. pinName .. "'")

    for _, conn in ipairs(self:_findTargetConnections(node.id, pinName)) do
        local targetNode = self.nodes[conn.toNode]
        if targetNode ~= nil then
            local targetType = self.registry:GetNodeType(targetNode.typeKey)
            -- Downstream nodes see no payload; ctx.exec is the input they arrived on.
            self:_executeNode(targetNode, targetType, depth + 1, nil, conn.toPin)
        end
    end
end

-- Entry point: begins a Fire at a Trigger (or any node) by running it directly.
-- The node's own run(ctx) is expected to call ctx:Fire(...) to propagate onward.
-- `payload` is an optional, engine-opaque value (typically an event table) surfaced
-- as ctx.payload on this entry node only; downstream nodes never see it and read
-- event data through Data pins instead (docs/adr/0009).
function Graph:Fire(nodeId, payload)
    local node = self.nodes[nodeId]
    assert(node ~= nil, "unknown node " .. tostring(nodeId))
    local nodeType = self.registry:GetNodeType(node.typeKey)
    assert(nodeType ~= nil, "unknown node type '" .. tostring(node.typeKey) .. "'")

    self._activeTrace = {}
    self:_executeNode(node, nodeType, 0, payload, nil)
    self.lastTrace = self._activeTrace
    self._activeTrace = nil
end

-- Entry point that enters a node through one of its exec INPUT pins, as if an upstream node
-- had fired a wire into `pinName`: the node's run(ctx) sees ctx.exec == pinName (and, like any
-- downstream entry, ctx.payload == nil — docs/adr/0009). Unlike Fire (which enters with no
-- exec pin, the Trigger case), this lets a caller exercise a single node through a chosen exec
-- input — the editor's per-pin "test" button. Propagation is identical to a real fire: any
-- ctx:Fire the node performs runs its downstream targets in turn.
function Graph:FireInput(nodeId, pinName)
    local node = self.nodes[nodeId]
    assert(node ~= nil, "unknown node " .. tostring(nodeId))
    local nodeType = self.registry:GetNodeType(node.typeKey)
    assert(nodeType ~= nil, "unknown node type '" .. tostring(node.typeKey) .. "'")
    local pin = nodeType.pins[pinName]
    assert(pin ~= nil and pin.kind == "exec" and pin.direction == "in",
        "'" .. tostring(pinName) .. "' is not an exec input pin on '" .. nodeType.key .. "'")

    self._activeTrace = {}
    self:_executeNode(node, nodeType, 0, nil, pinName)
    self.lastTrace = self._activeTrace
    self._activeTrace = nil
end

return Graph
