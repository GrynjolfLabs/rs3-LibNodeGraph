# Stateful node support: ctx.state and ctx.exec

ADR-0004 rule 3 namechecks stateful node types (Counter, DoOnce, Toggle/Gate) as the way
special execution semantics stay opt-in nodes rather than engine features. But the
`run(ctx)` surface of ADR-0003 (`In` / `Out` / `Fire`) made them unimplementable: a node
could not read its own prior state, and — with a single unified `run` and multiple
execution inputs — could not tell which input had fired. `LibNodeGraphStd` v1 shipped only
stateless Pure/flow nodes for exactly this reason. Two additions to the `run(ctx)` contract
close the gap.

## `ctx.state` — per-node persistent scratch

Every Node instance carries a `state` table, exposed as the plain field `ctx.state`. It
persists across Fires (like the stored `values` of an execution node) and is **runtime-only
— never serialized**. A Counter reads and writes `ctx.state.count`; a DoOnce tracks
`ctx.state.fired`; a Gate tracks `ctx.state.open`. This is consistent with ADR-0004 rule 3:
an execution node "stores on the instance" and later reads back — `ctx.state` is simply that
storage made first-class, decoupled from output Pins (a DoOnce's "have I fired" is not an
output).

Pure Nodes re-run on every pull (ADR-0004 rule 3), so state on a Pure Node would mutate on
each read — a misuse, forbidden by the same convention that keeps `ctx:Fire` out of Pure
Nodes, not by the signature.

**Not serialized** is a deliberate choice: a persisted behavior graph restores to a clean
slate (counters at their start, gates at `startClosed`), which is the least surprising
reload semantics for an event-driven editor. If durable counters are ever wanted, that is a
separate, opt-in serialization decision.

## `ctx.exec` — which execution input fired

A node reached by propagation now sees `ctx.exec`, the **name of the execution input Pin it
entered through**. It is `nil` for a Trigger (entered from outside — see ADR-0009) and for a
pulled Pure Node (no execution). This is what lets one unified `run` implement a node with
several execution inputs: Counter's `in` vs `reset`, Gate's `in`/`open`/`close`/`toggle`,
DoOnce's `in` vs `reset`. Terminator inputs (ADR-0004) are how those control inputs fire
nothing onward; `ctx.exec` is how `run` distinguishes them.

## Considered Options

- **`ctx:GetOut(pin)` only** — expose a node's own stored output for read-back. Covers
  Counter (count is an output) but not DoOnce/Gate (their state is not an output), and does
  nothing for the multi-input problem. Insufficient.
- **A distinct callback per execution input** — re-introduces role-specific callbacks that
  ADR-0003 rejected.
- **`ctx.state` + `ctx.exec` (chosen)** — one general state bag plus input identity; unified
  `run` stays; covers every stateful node in the roadmap.

## Consequences

Amends ADR-0003: the `run(ctx)` contract gains `ctx.state` and `ctx.exec` (alongside
`ctx.payload` from ADR-0009). No engine change to cycle detection is needed — a stateful
node's control inputs are declared as Terminators, which ADR-0004's propagation-graph rule
already handles (e.g. a Counter's `reset` loop). `LibNodeGraphStd` gains `std.counter`,
`std.doonce`, `std.gate`, and `std.flipflop`.
