# Two pin types: Execution Pins and Data Pins

GraphCore models control flow and data flow as two distinct Pin types (Execution Pins,
push-based and untyped; Data Pins, pull-based and typed) rather than a single unified
connection that carries both. We adopted this up front — while only Trigger and Action
node types exist — because the planned future node types (control, flow, boolean,
transformation) cannot be expressed in a unified model: a transformation computes data
without participating in the execution sequence, and a branch reads a data input to choose
between execution outputs.

## Considered Options

- **Unified connection** (one edge carries both "keep going" and a payload): simplest for
  the Trigger→Action base case, but the Pin/Connection model would need a rewrite the moment
  a non-execution node (e.g. a boolean or transformation) is added.
- **Two pin types** (chosen): mirrors Unreal Blueprints. Trigger = 1 Execution output +
  optional Data outputs; Action = 1 Execution input + optional Data inputs. Control/data
  flow stay independently inspectable, which the future UI wants to render as distinct wires.

## Consequences

Data flow is pull-based: when a Node executes it pulls values from its Data inputs, which may
recursively evaluate upstream data-producing nodes. This backward evaluation is the main
complexity the unified model would have avoided.
