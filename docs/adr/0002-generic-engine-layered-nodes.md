# Generic engine; node types layered above it

The engine (`LibNodeGraph`) is fully generic: it knows only Nodes, Pins, Connections,
execution, query, and inspection. It has no first-class "Trigger" or "Action" concept —
those are expressed as ordinary Node Types carrying an opaque `category` tag the engine
never interprets. The consumer's stated API ("give me all X triggers, filter, fire them")
is built from generic primitives (`GetNodesByCategory` / `GetNodesByType` + a consumer-side
filter + `Fire`).

Node types live in three layers:

- **`LibNodeGraph`** — the engine. No node types.
- **`LibNodeGraphStd`** — reusable, game-agnostic node types (branch, sequence, boolean,
  math/transform). A separate sibling library.
- **Watchdog** — game-specific node types (location/chat/damage triggers, play-sound /
  flash-screen actions). These require knowledge of the game and do not belong in a library.

## Considered Options

- **First-class Trigger/Action in the engine** — matches the mental model but re-couples the
  engine to a taxonomy that the roadmap (control/flow/boolean/transformation nodes) keeps
  expanding. Rejected.
- **Single library, node types in the consumer** — simplest, but the standard nodes are
  reusable and game-agnostic, so folding them into the game plugin would prevent reuse.
- **Two libraries + engine generic (chosen)** — engine stays generic; standard nodes are a
  reusable kit; game nodes stay in the game.

## Consequences

Two extra top-level deploy folders exist and are imported by Watchdog via sibling `require`
(assumed supported by the client loader; unverified). "Action" is not modeled at all — it is
simply a Node whose execution flow ends because it has no outgoing execution connection.
