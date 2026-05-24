# M54 — variable mutators + walker binding-scope tracking

**Date:** 2026-05-24
**Decision:** Add a new opt-in `:variable` target with `VariableReplace`
(in-scope variable → in-scope variable). Track binding scope in `Mut.EnvWalker`
as an **under-approximated** in-scope set (params + clause-head bindings).
**Defer `VariableToLiteral`** (type evidence is not cheaply available without
expansion, which the no-expansion contract forbids).

## Binding-scope tracking

`EnvWalker` gains a `bound_vars` set, threaded through the walk and surfaced on
`EnvSnapshot` (new field). It does **not** enter stable-id identity — IDs derive
from byte span + mutator + dispatch, never from snapshot fields — so adding it
is zero-churn by construction.

Bindings are collected at exactly two points:

- `walk_def` — function parameters, bound for the whole body.
- `walk_clauses` — clause-head patterns (case/fn/receive/try), bound for that
  clause body only.

Both revert when the enclosing `def`/clause returns (we thread only
`snapshots`/`candidates` back onto the outer state), keeping bindings scoped.
**`=` matches and with/for generators are intentionally NOT collected**: their
scoping is order-dependent and would risk leaking out-of-scope names. The
result is a safe under-approximation — every name in `bound_vars` at a node is
unconditionally in scope there.

`pattern_vars/1` extracts bound names from a pattern, excluding pins (`^x`
reads an existing binding) and `_`-prefixed / reserved (`__MODULE__`, …) names.

## VariableReplace

`collect_variable_candidates/2` emits a candidate for each variable **read**
(`context == nil`, trusted function body) that has ≥1 other in-scope variable.
The candidate carries the alternatives on `bound_vars`; the mutator emits up to
3 swaps (sorted), each `{name, meta, ctx}` → `{alt, meta, ctx}`.

Because every alternative is definitely in scope, a swap never produces an
**undefined variable** (no compile error from that path). Residual hazards:

- **Runtime behaviour change** — the point of the mutant; killable signal.
- **"unused variable" warning** when the swapped-out name had no other use.
  Handled reactively by `Mut.CompileRollback` under warnings-as-errors builds
  (consistent with M53); a plain warning otherwise leaves a valid mutant.

## VariableToLiteral — deferred

The PLAN lists `VariableToLiteral` as optional ("may defer if noise is
intractable"). Replacing a variable with a literal needs the binding's evident
type to avoid a flood of type-mismatch / always-crash mutants. The env walker
is syntactic and must not expand macros or run inference (M39 no-expansion
contract), so type evidence is not cheaply available. Deferred; revisit from
M55 corpus data if VariableReplace's signal justifies the type work.

## Validation

- Unit: `env_walker_variable_test.exs` (scope/alternatives, sole-binding and
  underscore/pin exclusion) + `variable_replace_test.exs` (gate + mutation).
- Plan (oracle-backed): `--enable variable` adds VariableReplace fallback
  mutants on real reads; base vs `+ :variable` plans share every existing
  stable id (zero churn).
- `bin/verify` green. Opt-in; corpus invalid/equivalent rates are M55.
