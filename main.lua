-- Public entry point for LibNodeGraph. Consumers require this file (see CONTEXT.md
-- for the domain glossary and docs/adr/ for the design rationale behind each choice
-- below) rather than reaching into the individual modules directly.

local Registry = require("registry")
local Graph = require("graph")
local Serialize = require("serialize")
local Json = require("json")

LibNodeGraph = {}

LibNodeGraph.NewRegistry = Registry.new
LibNodeGraph.NewGraph = Graph.new

-- The reserved placeholder Node Type key a lenient Deserialize assigns to a node whose real
-- type is missing (see serialize.lua's onUnknown = "placeholder"). Exposed so a consumer —
-- e.g. the Watchdog editor — can detect a placeholder (`node.typeKey == LibNodeGraph.UNKNOWN_TYPE`)
-- to render it read-only, without hardcoding the string.
LibNodeGraph.UNKNOWN_TYPE = Registry.UNKNOWN_TYPE

LibNodeGraph.Serialize = Serialize.Serialize
LibNodeGraph.Deserialize = Serialize.Deserialize
LibNodeGraph.ExportJSON = Serialize.ExportJSON
LibNodeGraph.ImportJSON = Serialize.ImportJSON

-- Exposed so a consumer can inject a native codec once available (docs/adr/0007).
LibNodeGraph.Json = Json

return LibNodeGraph
