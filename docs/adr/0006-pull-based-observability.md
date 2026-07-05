# Observability is pull-based; no event/observer bus

The engine exposes graph state through read-only accessors that the consumer pulls whenever it
renders (`GetNodes`, `GetConnections`, `GetPins`, `GetControl`, `GetLastValue`, `GetLastTrace`)
rather than emitting change events to subscribers. There is deliberately no observer/event bus.

The decisive reasons are specific to the runtime: the client is frame-based, so a UI renders
from current state every frame anyway (re-reading is the natural model); and the UI is the sole
mutator of graph structure, so there is no other actor changing structure behind its back for a
bus to report. Runtime value changes during `Fire` are surfaced by polling retained last-values
and the per-`Fire` Trace.

## Considered Options

- **Push/observer bus** (`NodeAdded`, `ConnectionMade`, `NodeFired`, …) — natural for reactive
  UIs, but serves a need a frame-based renderer with self-originated mutations does not have.
- **Pull-based accessors + opt-in Trace (chosen)** — matches frame rendering, no subscription
  lifecycle to manage.

## Consequences

Live firing visualization is driven by an opt-in, ordered per-`Fire` Trace the UI replays on its
own clock; the engine records what fired in what order (with values) but knows nothing about
timing, color, or animation. A reactive/non-frame consumer would need a push layer added later.
