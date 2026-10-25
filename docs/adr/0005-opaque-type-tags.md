# Data types are opaque string tags, with no coercion or subtyping

Data Pin types are plain string tags the engine never interprets. A Connection is legal when
the two tags are equal, or when a concrete output feeds an input tagged "any". An output tagged
"any" connects only to an input tagged "any": the value's type is not known, so it must not
enter a pin that expects a number, a string, or any other concrete tag. There is deliberately no implicit
coercion (e.g. number→string) and no subtyping/hierarchy (e.g. int is-a number), and runtime
values are never checked against the declared tag — tags govern connect-time legality and UI
presentation (wire color, editor widget) only.

This keeps the engine fully generic (it has no built-in types; Watchdog invents "coord",
"rs.item", etc. as needed) and keeps connection-checking trivial and predictable. Conversions
are explicit conversion nodes, consistent with how ordering (Sequence) and dedupe (DoOnce) are
opt-in nodes rather than engine features.

## Consequences

Mixing numeric kinds (int/float) or feeding a number where a string is wanted requires an
explicit conversion node rather than "just working". If a concrete need for coercion or
subtyping emerges, it can be added additively — as conversion nodes or a registered
compatibility rule — without changing existing graphs.
