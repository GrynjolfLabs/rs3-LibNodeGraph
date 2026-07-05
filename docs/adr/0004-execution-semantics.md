# Execution semantics: dumb signal propagation

The engine executes a `Fire` as a plain forward propagation of execution signals, with no
cleverness baked in. Four rules define it, and the guiding principle is that the engine stays
a simple, predictable propagator — special semantics are opt-in nodes (in `LibNodeGraphStd`),
not engine features.

1. **Fan-out is unordered.** An execution output with multiple Connections fires all of them
   in an unspecified order. Order is not part of the contract and is not exposed in the API
   (so the UI never manages per-wire ordinals). A `Sequence` node provides explicit ordering
   when needed.

2. **Per-arrival execution.** A node runs once for every execution signal that reaches it. If
   two paths reach the same node in one `Fire`, it runs twice. There is no dedupe; a `DoOnce`
   node provides join/once semantics when needed.

3. **Pull-resolution splits by node kind; no caching of pure nodes.**
   - A **Pure Node** (no execution pins) is re-evaluated on every `ctx:In` pull — its `run`
     executes fresh each time. This is always correct in the presence of stateful nodes (it
     always reads their *current* stored outputs), at the cost of redundant recomputation —
     negligible at expected graph sizes. Opt-in memoization can be added later if profiling
     ever justifies it.
   - An **execution node** (has execution pins — Trigger, Counter, …) cannot be re-evaluated on
     pull, because running it has side effects and, for a Trigger, no incoming signal. Instead
     it *sets* its data outputs during its `run` (when execution reaches or fires it) and those
     values are **stored on the instance**; later pulls read the stored value. Such an output
     only has a meaningful value after the node has executed in the current `Fire`.

   The two rules are consistent: because pure nodes re-run, they always observe the latest
   stored outputs of execution nodes, so no staleness arises.

4. **Cycles forbidden at connect-time, with a Terminator exception.** Cycle detection runs on
   the *propagation graph*: inter-node edges (a wire from output Pin to input Pin) plus
   intra-node edges (a non-Terminator execution input to every execution output of its node).
   A Connection that would close a cycle in that graph is rejected by `Connect()`. Because a
   Terminator input contributes no intra-node edges, a wire that loops back into one is legal
   (e.g. a Counter's output feeding its own `reset`). A runtime recursion-depth cap remains as
   a backstop against engine bugs.

## Consequences

Loops are never expressed as backward wires; they are single nodes (`ForEach`, `While`) that
iterate internally. The engine guarantees termination for any graph it accepts.
