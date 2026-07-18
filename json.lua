-- Bundled pure-Lua JSON codec, behind a swappable seam (docs/adr/0007). The library
-- never hard-wires this codec into call sites; consumers may inject an alternate
-- (e.g. a future native client JSON API) via Json.SetDefault.

local Json = {}

--- Encode -------------------------------------------------------------------------

local escapes = {
    ["\""] = "\\\"",
    ["\\"] = "\\\\",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
}

local function encodeString(s)
    local out = { "\"" }
    for i = 1, #s do
        local c = s:sub(i, i)
        local escaped = escapes[c]
        if escaped then
            out[#out + 1] = escaped
        elseif c:byte() < 0x20 then
            out[#out + 1] = string.format("\\u%04x", c:byte())
        else
            out[#out + 1] = c
        end
    end
    out[#out + 1] = "\""
    return table.concat(out)
end

local function isArray(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    if count == 0 then
        return true -- empty table encodes as []
    end
    for i = 1, count do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local encodeValue

local function encodeTable(t)
    if isArray(t) then
        local parts = {}
        for i = 1, #t do
            parts[#parts + 1] = encodeValue(t[i])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, v in pairs(t) do
        assert(type(k) == "string", "JSON object keys must be strings")
        parts[#parts + 1] = encodeString(k) .. ":" .. encodeValue(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(value)
    local t = type(value)
    if value == nil then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        return tostring(value)
    elseif t == "string" then
        return encodeString(value)
    elseif t == "table" then
        return encodeTable(value)
    end
    error("cannot encode value of type '" .. t .. "' to JSON")
end

--- Decode -------------------------------------------------------------------------

local function decode(text)
    local pos = 1
    local len = #text
    local parseValue

    local function skipWhitespace()
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parseString()
        pos = pos + 1 -- opening quote
        local out = {}
        while pos <= len do
            local c = text:sub(pos, pos)
            if c == "\"" then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                pos = pos + 1
                local e = text:sub(pos, pos)
                if e == "n" then
                    out[#out + 1] = "\n"
                elseif e == "t" then
                    out[#out + 1] = "\t"
                elseif e == "r" then
                    out[#out + 1] = "\r"
                elseif e == "b" then
                    out[#out + 1] = "\b"
                elseif e == "f" then
                    out[#out + 1] = "\f"
                elseif e == "u" then
                    local hex = text:sub(pos + 1, pos + 4)
                    out[#out + 1] = string.char(tonumber(hex, 16) % 256)
                    pos = pos + 4
                else
                    out[#out + 1] = e
                end
                pos = pos + 1
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string in JSON at position " .. pos)
    end

    local function parseNumber()
        local start = pos
        while pos <= len and text:sub(pos, pos):match("[%d%.%-%+eE]") do
            pos = pos + 1
        end
        return tonumber(text:sub(start, pos - 1))
    end

    local function parseArray()
        pos = pos + 1
        local out = {}
        skipWhitespace()
        if text:sub(pos, pos) == "]" then
            pos = pos + 1
            return out
        end
        while true do
            skipWhitespace()
            out[#out + 1] = parseValue()
            skipWhitespace()
            local c = text:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                break
            else
                error("expected ',' or ']' in JSON array at position " .. pos)
            end
        end
        return out
    end

    local function parseObject()
        pos = pos + 1
        local out = {}
        skipWhitespace()
        if text:sub(pos, pos) == "}" then
            pos = pos + 1
            return out
        end
        while true do
            skipWhitespace()
            assert(text:sub(pos, pos) == "\"", "expected string key in JSON object at position " .. pos)
            local key = parseString()
            skipWhitespace()
            assert(text:sub(pos, pos) == ":", "expected ':' in JSON object at position " .. pos)
            pos = pos + 1
            skipWhitespace()
            out[key] = parseValue()
            skipWhitespace()
            local c = text:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                break
            else
                error("expected ',' or '}' in JSON object at position " .. pos)
            end
        end
        return out
    end

    parseValue = function()
        skipWhitespace()
        local c = text:sub(pos, pos)
        if c == "\"" then
            return parseString()
        elseif c == "{" then
            return parseObject()
        elseif c == "[" then
            return parseArray()
        elseif c == "t" then
            assert(text:sub(pos, pos + 3) == "true", "invalid token in JSON at position " .. pos)
            pos = pos + 4
            return true
        elseif c == "f" then
            assert(text:sub(pos, pos + 4) == "false", "invalid token in JSON at position " .. pos)
            pos = pos + 5
            return false
        elseif c == "n" then
            assert(text:sub(pos, pos + 3) == "null", "invalid token in JSON at position " .. pos)
            pos = pos + 4
            return nil
        else
            return parseNumber()
        end
    end

    skipWhitespace()
    return parseValue()
end

--- Codec seam -----------------------------------------------------------------------

---A JSON codec: the pair of pure functions LibNodeGraph and its consumers use to cross the
---string boundary. `Json.Bundled` is the built-in implementation; a consumer may swap in a
---native client codec via SetDefault, provided it satisfies this same shape.
---@class LibNodeGraph.Codec
---@field encode fun(value: any): string   # Lua value -> JSON text
---@field decode fun(text: string): any    # JSON text -> Lua value

---@type LibNodeGraph.Codec
Json.Bundled = {
    encode = encodeValue,
    decode = decode,
}

-- Swapped out by the consumer if/when a native client JSON API becomes available.
---@type LibNodeGraph.Codec
Json.Default = Json.Bundled

---@param codec LibNodeGraph.Codec
function Json.SetDefault(codec)
    assert(type(codec) == "table" and type(codec.encode) == "function" and type(codec.decode) == "function",
        "codec must provide encode(table) and decode(string) functions")
    Json.Default = codec
end

return Json
