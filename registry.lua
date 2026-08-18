-- One Pin declaration in a Node Type definition.
---@class LibNodeGraph.PinDef
---@field name string
---@field kind "exec"|"data"
---@field direction "in"|"out"
---@field dataType string|nil     # Data Pin Type Tag; nil for exec pins
---@field default any             # data-input Control default
---@field terminates boolean|nil  # exec-input Terminator flag (ADR-0004)
---@field label string|nil

---One named pin-set on a Node Type (see ADR-0011). Same pin name in two modes must share
---kind/direction/dataType/terminates so a kept wire stays legal after SetMode.
---@class LibNodeGraph.NodeModeDef
---@field key string
---@field label string|nil
---@field pins LibNodeGraph.PinDef[]

-- The table passed to Registry:RegisterNodeType. Typing `run` here is what propagates the
-- RunContext contract to every `run = function(ctx)` a consumer writes: because `definition`
-- is typed, LuaLS infers `ctx`'s type from this field, so `ctx.<typo>` is a static error.
-- `pins` XOR `modes`: a type either has one pin list or several named modes. When `modes`
-- is set, `defaultMode` is required and the registered type's `pins`/`pinOrder` are the
-- default mode's set (type-only call sites still see a pin list).
---@class LibNodeGraph.NodeTypeDef
---@field category string
---@field displayName string|nil
---@field description string|nil      # optional one-line blurb shown in the Palette (see Watchdog ui/palette.lua)
---@field pins LibNodeGraph.PinDef[]|nil
---@field modes LibNodeGraph.NodeModeDef[]|nil
---@field defaultMode string|nil
---@field run fun(ctx: LibNodeGraph.RunContext<any>)
---@field preload? fun(node: table)   # optional resource-preload hook (see Watchdog runtime)
---@field hidden? boolean             # when true, excluded from palette/category iteration (GetNodeTypesByCategory)

---@class LibNodeGraph.Registry
---@field nodeTypes table<string, table>  # registered Node Types, keyed by their string key
---@field dataTypes table<string, table>  # optional Data Pin Type Tag metadata, keyed by tag
local Registry = {}
Registry.__index = Registry

-- The reserved, library-owned Node Type used to preserve a node whose real type is not
-- registered (see serialize.lua's lenient Deserialize). It is `hidden`, has no pins, and a
-- no-op `run`, making it inert against every execution path: firing into it dead-ends (the
-- no-op never calls ctx:Fire), and pulling from it yields nil (no exec pins -> treated as a
-- Pure Node whose run sets no output). Consumers may not register this key themselves.
Registry.UNKNOWN_TYPE = "__unknown__"

---@param typeKey string
---@param pinList LibNodeGraph.PinDef[]|nil
---@return table<string, table> pins
---@return string[] pinOrder
local function buildPins(typeKey, pinList)
    local pins = {}
    local pinOrder = {}
    for _, pin in ipairs(pinList or {}) do
        assert(type(pin.name) == "string" and pin.name ~= "", "pin missing name on node type '" .. typeKey .. "'")
        assert(pins[pin.name] == nil, "duplicate pin name '" .. pin.name .. "' on node type '" .. typeKey .. "'")
        assert(pin.kind == "exec" or pin.kind == "data",
            "pin '" .. pin.name .. "' on '" .. typeKey .. "' must have kind 'exec' or 'data'")
        assert(pin.direction == "in" or pin.direction == "out",
            "pin '" .. pin.name .. "' on '" .. typeKey .. "' must have direction 'in' or 'out'")

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
    return pins, pinOrder
end

---@return LibNodeGraph.Registry
function Registry.new()
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

    local hasPins = definition.pins ~= nil
    local hasModes = definition.modes ~= nil
    assert(not (hasPins and hasModes),
        "node type '" .. key .. "' must not declare both pins and modes")

    local pins, pinOrder, modes, defaultMode
    if hasModes then
        assert(type(definition.defaultMode) == "string" and definition.defaultMode ~= "",
            "node type '" .. key .. "' with modes must define defaultMode")
        modes = {}
        local signature = {}
        for _, modeDef in ipairs(definition.modes) do
            assert(type(modeDef.key) == "string" and modeDef.key ~= "",
                "mode missing key on node type '" .. key .. "'")
            assert(modes[modeDef.key] == nil,
                "duplicate mode key '" .. modeDef.key .. "' on node type '" .. key .. "'")
            local modePins, modeOrder = buildPins(key, modeDef.pins)
            for name, pin in pairs(modePins) do
                local prior = signature[name]
                if prior ~= nil then
                    assert(prior.kind == pin.kind and prior.direction == pin.direction
                            and prior.dataType == pin.dataType and prior.terminates == pin.terminates,
                        "pin '" .. name .. "' on '" .. key
                            .. "' must match kind/direction/dataType/terminates across modes")
                else
                    signature[name] = {
                        kind = pin.kind,
                        direction = pin.direction,
                        dataType = pin.dataType,
                        terminates = pin.terminates,
                    }
                end
            end
            modes[modeDef.key] = {
                key = modeDef.key,
                label = modeDef.label,
                pins = modePins,
                pinOrder = modeOrder,
            }
        end
        assert(modes[definition.defaultMode] ~= nil,
            "defaultMode '" .. definition.defaultMode .. "' is not a mode of '" .. key .. "'")
        defaultMode = definition.defaultMode
        pins = modes[defaultMode].pins
        pinOrder = modes[defaultMode].pinOrder
    else
        pins, pinOrder = buildPins(key, definition.pins)
    end

    self.nodeTypes[key] = {
        key = key,
        category = definition.category,
        displayName = definition.displayName or key,
        description = definition.description,  -- optional Palette blurb (see Watchdog ui/palette.lua)
        pins = pins,
        pinOrder = pinOrder,
        modes = modes,
        defaultMode = defaultMode,
        run = definition.run,
        preload = definition.preload,  -- optional resource-preload hook (see Watchdog runtime)
        hidden = definition.hidden and true or false,
    }
    return self.nodeTypes[key]
end

function Registry:GetNodeType(key)
    return self.nodeTypes[key]
end

-- Pins of a Node Type at a given instance mode: that mode's set, or the type's single
-- pin list (which is also the default mode when `modes` is set). Shared by Graph and
-- Serialize so instance lookups stay on one helper.
---@param nodeType table|nil
---@param mode string|nil
---@return table<string, table>|nil pins
---@return string[]|nil pinOrder
function Registry.pinSet(nodeType, mode)
    if nodeType == nil then
        return nil, nil
    end
    if nodeType.modes ~= nil and mode ~= nil then
        local modeDef = nodeType.modes[mode]
        if modeDef ~= nil then
            return modeDef.pins, modeDef.pinOrder
        end
    end
    return nodeType.pins, nodeType.pinOrder
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
