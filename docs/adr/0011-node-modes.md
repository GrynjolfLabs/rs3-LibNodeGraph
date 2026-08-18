# Node modes are instance metadata; reconstruct is Graph:SetMode

A Node Type may declare named **modes** (alternate pin-sets) instead of a single `pins`
list. A live Node stores `mode` as instance metadata — not a Data Pin. `Graph:SetMode`
reconstructs in place: the node **keeps its id**, the pin list becomes the new mode's set,
wires and Controls for vanished pins are dropped, and shared pin names keep their wires
and values.

This is an Unreal-style reconstruct. Hiding pin rows in a consumer UI would leave the
engine still owning every pin (Connect, cycle checks, Serialize would disagree with the
picture). Swapping `typeKey` via a hypothetical `SetTypeKey` would split one conceptual
node into many registered types. One `typeKey` plus `modes` is the chosen shape.

## Rules

- `pins` XOR `modes` at register. `defaultMode` is required when `modes` is set.
- The registered type still exposes `pins` / `pinOrder` as the **default mode**, so
  type-only call sites (palette, docs) keep working.
- Same pin **name** in two modes must share kind / direction / dataType / terminates, so a
  kept wire stays legal.
- Types without `modes` are unchanged: `Node.mode` and `ctx.mode` are `nil`.
- Unknown `SetMode` key: no-op, returns false, does not throw.
- Serialize writes `mode` whenever the type has modes (no schema version bump). A missing
  `mode` on disk loads as `defaultMode`.

## Consequences

Consumers that inspect pins must use `Graph:GetPins(id)` (instance, current mode) rather
than the type's default `pinOrder`, unless they genuinely have no instance. `run` may
branch on `ctx.mode`.
