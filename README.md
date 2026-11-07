# LibNodeGraph

LibNodeGraph is the graph engine Watchdog runs. An alert is a graph of nodes. This library keeps that graph in memory and runs it. It draws no window of its own.

## Installation

Declare it in `plugin.json`. The client injects the `LibNodeGraph` global.

```json
{
  "requiredDependencies": {
    "LibNodeGraph": "LibNodeGraph"
  }
}
```

## Usage

`NewRegistry()` builds a registry of node types. `NewGraph(registry)` builds a graph. `Serialize` and `Deserialize` save and load a graph. `ExportJSON` and `ImportJSON` do the same as JSON.

## Tests

From this folder:

```shell
lua tests/run.lua
```

## Contributing

### LLM/AI Usage Policy

When contributing to LibNodeGraph we permit the use of AI tools to assist in writing code. However, all contributions must be reviewed and approved by a human maintainer to ensure quality and adherence to project standards.

**DO NOT**

- Let LLMs generate your documentation for you.
- Submit Pull Requests generated solely by LLMs without human review.
- Have an LLM generate your Pull Request body.
