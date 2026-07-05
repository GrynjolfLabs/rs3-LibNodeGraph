# Unified run(ctx) behavior contract

Every Node Type defines its behavior through a single `run(ctx)` function rather than
role-specific callbacks (evaluate / execute / flow / match). The `ctx` object is the entire
behavior API: `ctx:In(pin)` pulls a data input (lazily evaluating upstream), `ctx:Out(pin,
value)` sets a data output, and `ctx:Fire(pin)` continues execution through a named
execution output. A node's role is defined by what it does with `ctx`, not by which callback
it supplies: a Pure Node only reads inputs and sets outputs; an action does a side effect and
never fires; a flow node fires one or more execution outputs.

## Considered Options

- **Role-specific callbacks** — minimal, self-documenting signatures, but the engine would
  have to dispatch on role, re-introducing the trigger/action/flow taxonomy that ADR-0002
  keeps out of the engine. Combined behaviors (data output + execution branching) get awkward.
- **Unified `run(ctx)` (chosen)** — one contract for every current and future node kind; the
  engine never branches on role; `ctx` is a single seam for the future UI and for testing.

## Consequences

Pin-usage legality (e.g. a Pure Node must not call `ctx:Fire`) is enforced by validation and
convention, not by the function signature.
