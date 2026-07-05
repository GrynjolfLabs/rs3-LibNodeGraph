# Node types register into an explicit Registry object, not global state

Node Type definitions (and optional data-type metadata) are registered into an explicit
`Registry` object that the consumer constructs and passes to `NewGraph`, rather than into
library-global state via a top-level `RegisterNodeType`. `LibNodeGraphStd` exposes
`Register(registry)` to install its standard nodes into whatever Registry it is given.

The decisive reason is repo-specific: the client re-executes a plugin on every save (the
idempotent-reload pattern in CLAUDE.md). Global registration state would re-register on every
reload and require overwrite-idempotency and stale-entry handling; a fresh Registry per load
sidesteps this entirely. It is also more testable (construct a Registry with only the types
under test, no global setup/teardown) and avoids ambient coupling — the dependency is explicit.

## Consequences

Slightly more ceremony than a bare global call: the consumer creates the Registry, installs
standard and game-specific types into it, and holds the reference to pass to graphs.
