# M53 — pattern-position literal mutators

**Date:** 2026-05-24
**Decision:** Mutate literals in `:match` positions for the int/atom/boolean/
nil/string subset under a new **opt-in `:pattern_literal` target**, routed to
the fallback engine. Handle structural hazards with a mix of **predictive
syntactic skips** (bitstring segments) and **reactive compile-rollback**
(clause collisions), rather than a full predictive cross-clause analysis.

## Surface

`Mut.EnvWalker` already classifies `context == :match` for clause heads and
match LHS. M53 emits scalar literal candidates there with `env_context:
:match`. The discoverable surface is naturally narrow because of two existing
walker properties:

- `descend/2` does not recurse into 2-tuples (`{a, b}`) or map pairs, so
  `{:ok, 42}` / `%{a: 1}` pattern literals are never visited.
- the env walker tracks no positional `ast_path` (it has always used
  `ast_path = []` + byte-span identity).

So only **bare arguments**, **list elements**, and **n-tuple (arity ≥ 3)
elements** are seen — a conservative set by construction. Float is excluded
from the subset (rare and noisy in patterns).

## Hazard handling

A `case` gate is never used (pattern candidates are fallback-routed, a source
patch), so the mutation output is always literal→literal — valid Elixir in a
pattern. Two structural hazards remain:

1. **Bitstring segment sizes** (`<<x::16>>`): a swapped size can produce an
   invalid/garbage match. **Predictively skipped** — `EnvWalker` sets an
   `in_bitstring` flag while descending `<<>>` segments and
   `match_literal_candidate?/2` refuses candidates there.

2. **Clause collisions / unreachable clauses** (`def f(:error)` mutated to
   `:ok` when `def f(:ok)` already exists). **Handled reactively** by
   `Mut.CompileRollback`: a placement that fails to compile is removed and the
   build retried. Rationale for not predicting these:
   - the path-less env walker has no cheap cross-clause / positional view, so
     predictive collision detection would need new sibling-tracking infra;
   - most collisions *do* compile (an `unreachable clause` warning, not an
     error) and yield valid, usually-killable mutants — they are legitimate
     signal, not noise;
   - warnings-as-errors builds turn the warning into a compile failure, which
     rollback already removes (so it never reaches results as a false signal).

   If M55's corpus data shows a high pattern-literal invalid rate, revisit with
   predictive sibling tracking.

## Routing & enablement

`:pattern_literal` is a new target, **not** in the default-on tier. The five
mutators (Integer/Atom/Boolean/Nil/String) carry it alongside their existing
target and admit `env_context == :match`. `Orchestrator.pattern_literal_results`
gates on `:pattern_literal in enabled_targets`; otherwise the candidates become
`:pattern_literal_engine_disabled` skips.

## Validation

- Discovery unit test (`env_walker_pattern_literal_test.exs`): bare/list/
  n-tuple `:match` candidates emitted; bitstring sizes and floats skipped;
  body literals stay `env_context: nil`.
- Firing (oracle-backed plan on a pattern-literal fixture): `def handle(:error)`,
  `def status(404)`, `def tag([1, "name"])` each produce fallback mutants
  (`engine: :fallback`) for the matched literals.
- Zero stable-id churn: demo_app `[:dispatch, :guard, :env_walker]` vs
  `+ :pattern_literal` plans are identical. `bin/verify` green.

Corpus invalid/equivalent rates and a default-policy decision are M55.
