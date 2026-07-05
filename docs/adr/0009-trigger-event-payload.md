# Trigger event payload injection

A Trigger is "entered from outside the Graph when a matching event occurs" (CONTEXT.md),
but until now the engine gave it no channel to receive the event's data. `Graph:Fire`
took only a node id, and the `run(ctx)` surface (ADR-0003) was `In` / `Out` / `Fire` —
all of which move data *within* the Graph. A chat Trigger fired on an incoming message
had no way to see the message text, so it could neither match on it nor republish it.

`Graph:Fire(nodeId, payload)` now accepts an optional, **engine-opaque** payload
(typically an event table, e.g. `{ text = "...", channel = "..." }`). It is surfaced as
the plain field **`ctx.payload`** — data, not an operation, so a field rather than a
`ctx:Payload()` method, matching how the RS3 client hands event data to a callback.

**Visibility is the entry node only.** `ctx.payload` is set on the node passed to `Fire`
and is `nil` on every node reached by downstream propagation (`ctx:Fire`) or by a data
pull. This keeps the pin dataflow model intact: a Trigger reads `ctx.payload`, does its
matching, and republishes whatever downstream needs onto its Data output Pins via
`ctx:Out`; downstream nodes pull those pins and never reach into the event. This is the
mechanism ADR-0004 rule 3 already describes for an execution node setting its outputs —
this ADR just names where a Trigger's output values originate.

## Considered Options

- **Graph-global payload for the whole Fire** — store it like `_activeTrace` so any node's
  `ctx.payload` returns it. Simpler to thread, but lets any node bypass its pins and read
  the event directly, undercutting the pin model. Rejected.
- **`ctx:Payload()` method** — uniform with `In`/`Out`/`Fire`, but payload is data, not
  behavior; a field reads more naturally and needs no call.
- **Entry-node-only `ctx.payload` field (chosen)** — the payload reaches exactly the one
  node "entered from outside"; everyone else uses pins.

## Consequences

Amends ADR-0003: the `run(ctx)` contract gains a fourth member, `ctx.payload`. The payload
is runtime-only — it is never serialized (serialization persists structure, not a live
event). Pin-usage convention still holds: only Triggers should read `ctx.payload`, the
same way only flow nodes should call `ctx:Fire`.
