# M43 — EnvWalker consolidation: deferred to v1.16 (release valve exercised)

**Date:** 2026-05-23
**Decision:** Do **not** consolidate the four `AstWalk` walkers into
`EnvWalker` in v1.15. Keep the parallel fifth-source design. Reschedule
to v1.16 at zero downstream cost (M44/M45 do not depend on it).

## Why

M43 had a hard gate: stable IDs byte-identical for every existing
mutator on demo_app, plug_crypto, Decimal, plug. *"Any churn stops the
migration — fall back to the parallel fifth-source design and reschedule
to v1.16"* (PLAN §M43).

A pre-implementation spike against real plan data shows the gate **cannot
be met** by making `EnvWalker` the single candidate source, because the
two walkers bake incompatible `ast_path` encodings into stable IDs.

### Evidence (plug_crypto v2.1.1, `--enable …,env_walker`)

| Mutator (source) | Mutants | Distinct `ast_path_hash` |
|---|---:|---:|
| StringLiteral (`EnvWalker`) | 7 | **1** |
| IntegerLiteral (`AstWalk.body_literal`) | 92 | 52 |
| BooleanLiteral (`AstWalk.body_literal`) | 17 | 17 |
| Arithmetic (`AstWalk.dispatch`) | 26 | 12 |

`EnvWalker` emits `ast_path = []` for every literal candidate; the single
shared StringLiteral hash is exactly `path_hash([])`:

```
:sha256 |> :crypto.hash(:erlang.term_to_binary([]))
        |> binary_part(0, 16) |> Base.encode16(case: :lower)
#=> "4309bcba566dde47811c47fa17eda825"   # == every StringLiteral hash
```

`EnvWalker` differentiates string literals by **byte span**, not path —
the deliberate M41 design (string literals at the same `ast_path` would
otherwise collide; M41 fixed identity by falling back to `:end_of_expression`
byte spans). `AstWalk` differentiates by a detailed positional path built
in `enter_path/2` as `parent.path ++ [{:elem, parent.kind, next_index}]`.

### Why no clean merge exists

A single walker must pick one path encoding:

- **Use AstWalk's detailed paths** → the 7 StringLiteral hashes change
  from the constant `4309bcba…` to 7 distinct values → all StringLiteral
  stable IDs churn.
- **Use EnvWalker's `[]`** → ~150 AstWalk hashes collapse to one →
  massive collision and churn across dispatch/guard/attribute/body_literal.

A per-candidate-type path policy (keep detailed paths for AstWalk types,
emit `[]` for literals) would technically preserve identity — but then
the path-producing traversal *remains* `AstWalk`'s `Macro.traverse` +
frame stack. `EnvWalker`'s bespoke recursive descent visits children in a
different order than `Macro.traverse` pre-order (e.g. `=` walks rhs before
lhs; `case` walks the scrutinee before clauses), which reassigns
`next_index` and churns every dispatch/guard/attribute/body_literal ID.
`EnvWalker` cannot be the path source without becoming `AstWalk`.

Independently: `body_literal` and `string_literal` are discovered over a
`literal_encoder`-parsed AST (literals wrapped in `{:__block__, …}`),
while `dispatch`/`guard`/`attribute` walk the plain AST. Two different
ASTs cannot share one traversal.

## Method

`mix mut --debug-plan` against demo_app (fixture) and a pinned plug_crypto
v2.1.1 checkout, two flag sets (with/without `env_walker`), extracting the
sorted `stable_id` set from `plan.debug.json`. The incompatibility is
visible directly in the baseline plan (StringLiteral all share one hash;
AstWalk literals do not), so no churning refactor was written — the
existing plan data is conclusive.

Baselines captured: demo_app 33/33 (no string literals — weak signal),
plug_crypto 173 (no env_walker) / 180 (with env_walker, +7 StringLiteral).

## Consequence

- `EnvWalker` remains the opt-in parallel fifth source (unchanged).
- M44/M45 literal mutators target `EnvWalker` as-is, exactly as the PLAN
  anticipated.
- A future v1.16 M43 must redesign as **AstWalk absorbs EnvWalker's
  trust/context classification into the existing frame-based traversal**
  (keeping AstWalk's path encoding), not the reverse. That is a different,
  larger milestone and should carry its own stable-id migration analysis
  if any encoding changes.

---

# M51 — Consolidation design + proof (v1.16 spike, 2026-05-23)

**Outcome: FEASIBLE, but recommend DEFER (low ROI).** No migration code
shipped. The proof retires the central risk; the recommendation is to
implement only when a maintenance trigger justifies it.

## The two incompatibilities, restated

1. **Path encoding** — env-walker literals key identity off byte spans
   with `ast_path = []`; the AstWalk families (dispatch/guard/attribute/
   body_literal) key off positional `{:elem, kind, idx}` paths.
2. **Parse mode** — dispatch/guard/attribute walk the **plain** AST;
   body_literal AND the env-walker literals walk the **`literal_encoder`**
   AST (literals wrapped in `{:__block__, …}`).

## Refined redesign (grounded in the current code)

The five passes collapse to **two frame-based traversals, one per parse
mode** — not one:

- **Pass A — plain AST.** Merge `dispatch_candidates` +
  `guard_candidates` + `attribute_candidates` (today three separate
  `Macro.traverse` calls already sharing the `enter_path`/`push_frame`
  frame model) into one pre/post that runs all three detectors. Positional
  paths unchanged → no churn.
- **Pass B — `literal_encoder` AST.** Merge `body_literal_candidates`
  with the env-walker literals (string/float/nil/atom/collection). `EnvWalker`'s
  bespoke recursive descent is **deleted**; its env classification is
  absorbed into Pass B's frame model. Per-candidate-type path policy:
  body_literal keeps positional paths (its identity); env-walker literals
  emit `ast_path = []` and keep byte-span identity (their identity). Both
  read scope/context/trust from the current frame.

This is viable because **`body_literal` already does AstWalk-style env
classification** on the `literal_encoder` AST: `body_position?(path)`
decides function-body vs guard vs pattern vs quote vs attribute purely
from the ancestor path. Pass B is body_literal's traversal, extended to
also emit the env-walker literals.

## Proof (`bench/spike/m51_consolidation_proof.exs`, throwaway)

For literals placed in each syntactic position, compare the two existing
body-eligibility classifiers — `body_literal`'s frame/path model
(`body_position?`) vs `EnvWalker`'s env descent:

| Position | path/frame clf | env clf | |
|---|---|---|---|
| function body | eligible | eligible | agree |
| guard | no | no | agree |
| function-head pattern | no | no | agree |
| match LHS | no | no | agree |
| quote body | no | no | agree |
| module attribute | no | no | agree |
| **opaque-macro body** | **eligible** | **no** | **trust gap** |

**The frame/path model already reproduces EnvWalker's scope + context
classification (6/7).** The sole divergence is the **trust** dimension:
EnvWalker marks descendants of an unknown macro call `:untrusted` and
skips them; `body_position?` has no trust notion. So Pass B must add
opaque-macro boundary tracking (the `Mut.OpaquePolicy` logic EnvWalker
already encapsulates) to its pre/post hooks.

**Path orthogonality** (no churn for path-based candidates): `enter_path/2`
computes `parent.path ++ [{:elem, parent.kind, parent.next_index}]` from
only those three frame keys. Adding `scope`/`context`/`trust` fields to
the frame map cannot change a path — provable by inspection; body_literal
candidate paths are already independent of any env state.

## Go/no-go

- **Feasibility: GO.** No fundamental blocker. The path encodings are
  reconcilable via per-type policy within one traversal; env classification
  is reproducible from frames; the only new work is the bounded trust layer.
- **Recommendation: DEFER.** ROI is low:
  - **No perf payoff** — M39 measured env-walker cold-walk at <1% of
    oracle wall; the parallel fifth-source design carries no meaningful tax.
  - **Only payoff is dedup** (~5 passes → 2; `EnvWalker`'s ~700-line
    descent deleted), against a **real byte-identity migration risk**
    concentrated in reproducing EnvWalker's exact opaque-macro/quote trust
    classification — any divergence churns env-walker literal eligibility.
- **Trigger to revisit:** a third `literal_encoder` consumer appears, the
  dual-walker maintenance cost bites, or a bug forces unification.

## Estimate (for a v1.17 implementation milestone, if triggered)

- ~500–700 LOC touched; **net reduction** ~300–500 LOC (EnvWalker descent
  removed, minus the trust layer added to Pass B).
- Hard gate identical to M43: stable IDs byte-identical for **every**
  existing mutator (dispatch/guard/attribute/integer/boolean + string/
  float/nil/atom/collection) on demo_app, plug_crypto, Decimal, plug,
  phoenix_html. The risk surface is Pass B's trust classification; gate
  with the M40/M41 stable-id diff harness per parse mode.
- No-expansion grep gate (M40) extended to the merged Pass B.
