# LibNodeGraph

The graph domain for a node-based, event-driven behavior editor (Unreal Blueprints-style)
used by the Watchdog plugin. LibNodeGraph owns only the generic graph model and its
execution — no UI, no game-client API calls, and no game-specific node types. Consumers
register their own node types, feed in events, and attach their own presentation.

## Language

**Graph**:
A collection of Nodes and the Connections between them, owned and executed as a unit.
_Avoid_: Blueprint, script, tree, network

**Node**:
A single unit in a Graph exposing Pins. Every Node is an instance of a registered Node Type.
_Avoid_: Vertex, block, box

**Node Type**:
A registered template — key, Pin declarations, display metadata, and behavior — that Nodes
are instances of. Identified by a stable string key used for serialization.
_Avoid_: Node class, node kind, template, descriptor

**Registry**:
An explicit object holding the Node Type definitions and optional data-type metadata a Graph
draws on. Constructed by the consumer and passed to a Graph at creation, rather than being
global library state. `LibNodeGraphStd` installs its standard Node Types into a Registry the
consumer hands it.
_Avoid_: Catalog, library (overloaded), global registry, type table

**Category**:
An opaque consumer-defined tag on a Node Type used to group and query Nodes (e.g. "trigger",
"action"). The engine stores and filters on it but never interprets its meaning.
_Avoid_: Kind, group, tag, class

**Pure Node**:
A Node with only Data Pins and no Execution Pins. It never participates in execution flow;
it is evaluated on demand when one of its Data outputs is pulled.
_Avoid_: Data node, function node, expression node

**Pin**:
A typed attachment point on a Node where Connections terminate. Every Pin is either an
Execution Pin or a Data Pin, and is either an input or an output.
_Avoid_: Port, socket, slot, terminal

**Execution Pin**:
A Pin that carries control flow ("run next") — push-based, forward-directed, untyped.
_Avoid_: Exec pin (in prose), flow pin, control pin

**Data Pin**:
A Pin that carries a typed value, supplied on demand ("give me your value") rather than by
firing. Pulled backward through the Graph when a Node executes.
_Avoid_: Value pin, parameter, argument, field

**Type Tag**:
An opaque string naming a Data Pin's type (e.g. "bool", "coord"). Two Data Pins may connect
iff their tags are equal or either is the wildcard "any". The engine never interprets a tag's
meaning and never checks runtime values against it — tags govern connect-time legality and UI
presentation only.
_Avoid_: Data type, value type, class

**Connection**:
A directed link from an output Pin to an input Pin. Execution Pins connect only to Execution
Pins; Data Pins only to Data Pins.
_Avoid_: Edge, wire, link, line

**Terminator**:
An Execution input Pin that fires no Execution output when run, so execution flow ends there.
Declared per Node Type by a boolean `terminates` flag on the input Pin (default false). An
Action's input is a Terminator implicitly, by having no Execution outputs at all. Terminators
break what would otherwise be an execution cycle, so a Connection that loops back into one is
legal.
_Avoid_: Sink pin, dead end, end pin

**Trigger**:
A node type with no Execution input, entered from outside the Graph when a matching event
occurs. The origin of every execution flow. Receives the event's data as the Payload and
republishes what downstream needs onto its Data output Pins.
_Avoid_: Source, event node, entry, root

**Payload**:
An engine-opaque value (typically an event table) handed to a Fire and surfaced as
`ctx.payload` on the fired Trigger only — never on downstream Nodes, which read event data
through Pins. Runtime-only; never serialized.
_Avoid_: Event data (as a distinct concept), args, context, message

**Action**:
A node type with an Execution input and no Execution output. The terminus of an execution
flow; where a side effect happens.
_Avoid_: Sink, effect node, leaf, handler

**Control**:
The literal value stored on a data *input* Pin of a Node, used when that Pin has no incoming
Connection. It is the same kind of value a Connection would supply, so a Control can be
promoted to a Connection and back with no special casing. Every editable field on a Node is a
Control — there is no separate node-property concept.
_Avoid_: Property, setting, field, default (the declared fallback is the "default"; the
per-instance value is the Control)

**Mode**:
A named pin-set on a Node Type. A live Node stores `mode` as instance metadata (not a Data
Pin). `Graph:SetMode` reconstructs in place: same id, new pin list; Connections and Controls
for vanished Pins are dropped. Types that omit `modes` have `Node.mode` / `ctx.mode` nil.
_Avoid_: Variant, preset, profile, pin-set (in prose — that's the implementation)

**Fire**:
To begin execution at a Trigger, pushing control flow along Execution Connections until it
reaches Actions. Optionally carries a Payload for the entered Trigger.
_Avoid_: Run, invoke, execute (as the verb for starting a Trigger), emit

**Node State**:
A per-Node table (`ctx.state`) that persists across Fires, giving a stateful Node Type
(Counter, DoOnce, Gate, FlipFlop) somewhere to remember prior runs. Runtime-only; never
serialized, so a reloaded Graph starts from a clean slate. A Pure Node must not use it, as
it re-runs on every pull.
_Avoid_: Memory, store, scratch, instance data

**Entered Pin**:
The Execution input a Node's run was reached through, exposed as `ctx.exec`, letting one
unified `run` distinguish a Node's several execution inputs (e.g. Counter's `in` vs
`reset`). Nil for a Trigger and for a pulled Pure Node.
_Avoid_: Active pin, trigger pin, source pin

**Trace**:
The ordered record of a single `Fire` — the execution traversals, node executions, and data
pulls (with the values carried) that occurred, in order. Recorded only while tracing is
enabled and exposed for the consumer to replay as a live visualization. It carries no timing
or presentation data.
_Avoid_: Log, history, timeline, journal

## The run(ctx) contract and how it's enforced

Every Node Type's `run` receives one argument, `ctx`, whose complete shape is the
`LibNodeGraph.RunContext` class defined in [graph.lua](graph.lua) (`nodeId`, `payload`,
`exec`, `mode`, `state`, and the methods `In`/`Out`/`Fire`). That class is the single source of truth;
`_makeCtx` is kept in lockstep with it. This contract has been silently mis-assumed before — a
node read `ctx.pin`/`ctx.id` (fields the engine never sets) instead of `ctx.exec`/`ctx.nodeId`,
and nothing caught it — so three independent guards now exist, and a node author should rely on
all three rather than trusting a remembered field name:

1. **Test node behavior against a real Graph, never a fabricated ctx.** A test that hand-builds
   a `ctx` table can only ever agree with whatever the node's code already assumes — it is
   structurally blind to a divergence from the real engine, which is exactly how `ctx.pin`
   passed its unit tests. Build a real `Registry` + `Graph`, `AddNode`, set Controls, and drive
   the node with `Graph:FireInput(id, execPin)` (enter through a chosen exec input) or
   `Graph:Fire(id)` (enter with no exec pin), then assert on the observable effect. See
   Watchdog's `tests/test_screen_marker.lua` / `tests/test_infobox_node.lua` for the pattern.
2. **The RunContext field guard (runtime).** The table `_makeCtx` returns errors on *read* of
   any field not on the contract, so a typo'd or assumed-nonexistent field fails loudly the
   first time it's touched (in tests and dev) rather than evaluating to a silent `nil`.
   Declared-but-absent fields (`exec` on a Trigger, `payload` downstream) still read as `nil`.
3. **Static typing (LuaLS).** `RegisterNodeType`'s `definition` param is typed
   `LibNodeGraph.NodeTypeDef`, whose `run` field carries the `RunContext` type — so annotating a
   consumer's registration function `---@param registry LibNodeGraph.Registry` propagates the
   type to `ctx` at the `run = function(ctx)` site, and `ctx.<typo>` becomes an `undefined-field`
   diagnostic. Verify a tree with:

   ```bash
   lua-language-server --check <plugin-dir> --checklevel=Warning
   ```

   (exit code is non-zero when problems are found, suitable for CI).
