-- One Pin declaration in a Node Type definition.
---@class LibNodeGraph.PinDef
---@field name string
---@field kind "exec"|"data"
---@field direction "in"|"out"
---@field dataType string|nil     # Data Pin Type Tag; nil for exec pins
---@field default any             # data-input Control default
---@field terminates boolean|nil  # exec-input Terminator flag (ADR-0004)
---@field label string|nil

-- The table passed to Registry:RegisterNodeType. Typing `run` here is what propagates the
-- RunContext contract to every `run = function(ctx)` a consumer writes: because `definition`
-- is typed, LuaLS infers `ctx`'s type from this field, so `ctx.<typo>` is a static error.
---@class LibNodeGraph.NodeTypeDef
---@field category string
---@field displayName string|nil
---@field description string|nil      # optional one-line blurb shown in the Palette (see Watchdog ui/palette.lua)
---@field pins LibNodeGraph.PinDef[]
---@field run fun(ctx: LibNodeGraph.RunContext)
---@field preload? fun(node: table)   # optional resource-preload hook (see Watchdog runtime)
---@field hidden? boolean             # when true, excluded from palette/category iteration (GetNodeTypesByCategory)

-- `Registry.__index = Registry` is set inside Registry.new, NOT at the top level: a
-- self-referential module table triggers an infinite traversal in the client at require time
-- (freeze+crash).
---@class LibNodeGraph.Registry
---@field nodeTypes table<string, table>  # registered Node Types, keyed by their string key
---@field dataTypes table<string, table>  # optional Data Pin Type Tag metadata, keyed by tag
local Registry = {}

-- The reserved, library-owned Node Type used to preserve a node whose real type is not
-- registered (see serialize.lua's lenient Deserialize). It is `hidden`, has no pins, and a
-- no-op `run`, making it inert against every execution path: firing into it dead-ends (the
-- no-op never calls ctx:Fire), and pulling from it yields nil (no exec pins -> treated as a
-- Pure Node whose run sets no output). Consumers may not register this key themselves.
Registry.UNKNOWN_TYPE = "__unknown__"

---@return LibNodeGraph.Registry
function Registry.new()
    Registry.__index = Registry
    local self = setmetatable({
        nodeTypes = {},
        dataTypes = {},
    }, Registry)
    -- Register the placeholder type up front so any Registry can resolve `__unknown__`
    -- during a lenient Deserialize without the consumer opting in. Inserted directly
    -- (not via RegisterNodeType, which reserves the key against consumer registration).
    self.nodeTypes[Registry.UNKNOWN_TYPE] = {
        key = Registry.UNKNOWN_TYPE,
        category = nil,
        displayName = "Unknown",
        description = "Placeholder for a node whose type is not registered.",
        pins = {},
        pinOrder = {},
        run = function() end,
        hidden = true,
    }
    return self
end

---@param key string
---@param definition LibNodeGraph.NodeTypeDef
function Registry:RegisterNodeType(key, definition)
    assert(type(key) == "string" and key ~= "", "node type key must be a non-empty string")
    assert(key ~= Registry.UNKNOWN_TYPE,
        "node type key '" .. Registry.UNKNOWN_TYPE .. "' is reserved by LibNodeGraph")
    assert(type(definition) == "table", "node type definition must be a table")
    assert(type(definition.run) == "function", "node type '" .. key .. "' must define run(ctx)")

    local pins = {}
    local pinOrder = {}
    for _, pin in ipairs(definition.pins or {}) do
        assert(type(pin.name) == "string" and pin.name ~= "", "pin missing name on node type '" .. key .. "'")
        assert(pins[pin.name] == nil, "duplicate pin name '" .. pin.name .. "' on node type '" .. key .. "'")
        assert(pin.kind == "exec" or pin.kind == "data",
            "pin '" .. pin.name .. "' on '" .. key .. "' must have kind 'exec' or 'data'")
        assert(pin.direction == "in" or pin.direction == "out",
            "pin '" .. pin.name .. "' on '" .. key .. "' must have direction 'in' or 'out'")

        pins[pin.name] = {
            name = pin.name,
            kind = pin.kind,
            direction = pin.direction,
            dataType = pin.dataType,
            default = pin.default,
            terminates = pin.terminates and true or false,
            label = pin.label,
        }
        pinOrder[#pinOrder + 1] = pin.name
    end

    self.nodeTypes[key] = {
        key = key,
        category = definition.category,
        displayName = definition.displayName or key,
        description = definition.description,  -- optional Palette blurb (see Watchdog ui/palette.lua)
        pins = pins,
        pinOrder = pinOrder,
        run = definition.run,
        preload = definition.preload,  -- optional resource-preload hook (see Watchdog runtime)
        hidden = definition.hidden and true or false,
    }
    return self.nodeTypes[key]
end

function Registry:GetNodeType(key)
    return self.nodeTypes[key]
end

-- Hidden types (e.g. the reserved `__unknown__` placeholder) are excluded, so a consumer's
-- palette iterating a category never surfaces a library-internal type.
function Registry:GetNodeTypesByCategory(category)
    local out = {}
    for _, nodeType in pairs(self.nodeTypes) do
        if nodeType.category == category and not nodeType.hidden then
            out[#out + 1] = nodeType
        end
    end
    return out
end

-- Optional per-Type-Tag metadata, e.g. { encode = fn(value), decode = fn(raw) }
-- for control values that aren't already JSON-safe (see docs/adr/0007).
function Registry:RegisterDataType(tag, definition)
    assert(type(tag) == "string" and tag ~= "", "data type tag must be a non-empty string")
    self.dataTypes[tag] = definition or {}
end

function Registry:GetDataType(tag)
    if tag == nil then
        return nil
    end
    return self.dataTypes[tag]
end

return Registry
