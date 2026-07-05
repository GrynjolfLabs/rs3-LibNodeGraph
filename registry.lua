local Registry = {}
Registry.__index = Registry

function Registry.new()
    return setmetatable({
        nodeTypes = {},
        dataTypes = {},
    }, Registry)
end

function Registry:RegisterNodeType(key, definition)
    assert(type(key) == "string" and key ~= "", "node type key must be a non-empty string")
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
        pins = pins,
        pinOrder = pinOrder,
        run = definition.run,
    }
    return self.nodeTypes[key]
end

function Registry:GetNodeType(key)
    return self.nodeTypes[key]
end

function Registry:GetNodeTypesByCategory(category)
    local out = {}
    for _, nodeType in pairs(self.nodeTypes) do
        if nodeType.category == category then
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
