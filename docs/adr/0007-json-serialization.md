# JSON is the first-class share + persist format, behind a swappable codec

A Graph serializes to a canonical, JSON-safe Lua table (`Serialize` / `Deserialize`), and
`ExportJSON` / `ImportJSON` are thin wrappers that encode/decode that table. JSON is the single
format used for **both** sharing graphs between users **and** local persistence: because
`persistentdb` structured data is effectively a flat scalar store (the DevTools pattern stores
nested structures as one encoded string under a key), a graph is persisted by storing its
`ExportJSON()` string — the same string a user shares. There is no separate saved-vs-shared
representation.

The library never calls `persistentdb` itself; it only produces/consumes tables and strings.
The consumer (Watchdog) owns actual persistence. This keeps the library free of both UI and
client-API dependencies.

## The codec is a swappable seam (pinned)

The client is expected to gain a native JSON API soon. To absorb that without touching
serialization logic or the format, JSON encoding/decoding goes through a small injectable
codec interface (`encode(table) → string`, `decode(string) → table`). A bundled pure-Lua codec
is the default/fallback; when a native JSON global is available it is preferred (auto-detected
or injected by the consumer). Do not hard-wire the bundled codec into call sites.

## Consequences

- Control values must be JSON-safe (primitives, arrays, string-keyed tables — a coord `{x, y}`
  qualifies). Exotic value types supply an optional per-Type-Tag `encode`/`decode` hook via the
  type registry; most types need nothing.
- A `version` field is included so graphs shared from an older library version can be migrated
  on import — more important for shared files than for local saves.
