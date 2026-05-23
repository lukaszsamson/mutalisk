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
