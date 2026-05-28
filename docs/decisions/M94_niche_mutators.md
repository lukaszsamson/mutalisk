# M94 — Niche mutators: PipelineDropStage + MapUpdateDrop + ReceiveTimeout (v1.26)

**Date:** 2026-05-28

Three opt-in fallback-routed mutators covering the deferred-niche AST
shapes named in the v1.25 horizon. Each is gated by its own opt-in
target so the default plan stays unchanged; M95 measures whether
graduation is warranted.

## `Mut.Mutator.PipelineDropStage`

Drop a **middle** stage from a `|>` chain: `a |> f() |> g() |> h()`
becomes `a |> f() |> h()` when `g` is dropped. The mutation is
observable on tests that depend on what `g/1` did to the intermediate
value.

Implementation in `Mut.AstWalk.pipeline_drop_candidates/2`: walk the
AST with `Macro.traverse`, intercept the **top** of each `|>` chain
(replacing the matched node with a leaf placeholder so nested pipes
inside the chain aren't re-processed), flatten into
`[input, s1, s2, ..., sN]`, emit one candidate per middle position
(0-indexed `2..N-2`). Span is custom: leftmost leaf's `:line`/`:column`
to rightmost call's `:closing` (or `:end_line`/`:end_column`).

Hazards (per the v1.26 PLAN):

- **First stage skipped** — "destroys the input": dropping the first
  stage means the input flows raw to the next stage; far closer to
  noise than signal.
- **Last stage skipped** — refactoring-equivalent if the test suite
  doesn't distinguish the upstream chain's value from the final
  transform's result.
- **Chains shorter than 3 stages skipped** (i.e. < 4 flat-list
  elements) — no middle to drop.

Opt-in via the `:pipeline_drop` target.

## `Mut.Mutator.MapUpdateDrop`

`%{m | k: v, a: 1}` → `m`. The mutation is observable on any test
that asserts on the updated keys; tests that don't exercise the
update leave the mutant surviving (the "is this update exercised?"
signal we want).

Implementation in `Mut.AstWalk.map_update_drop_candidates/2`: prewalk,
match `{:%{}, meta, [{:|, _, [base, updates]}]}`, emit one candidate
per occurrence. Span via `Compute.from_meta` (the `%{}` node has
`:closing` for the `}` position).

The plan note about "hazard-skip when result is not bound/returned"
(would catch the trivially-equivalent class where the
`%{m | …}` expression's value is discarded) is **not gated**
statically — the parent context isn't always visible (pipelines,
function args). M95's equivalent-rate measurement quantifies the
resulting noise; v1.27+ refines if warranted.

Plain map literals `%{a: 1, b: 2}` are skipped — they don't have the
"preserve base / drop update" shape. Map-key mutations on plain
literals would be a separate sub-shape.

Opt-in via the `:map_update_drop` target.

## `Mut.Mutator.ReceiveTimeout`

In `receive do … after t -> body end`, three mutations per candidate:

1. **`t` -> `0`** — immediate timeout; the `body` runs at once,
   bypassing message-handler clauses.
2. **`t` -> `:infinity`** — never times out; receive waits forever
   for a matching message (typically a hung test → killed).
3. **drop the `after` clause** — structurally distinct from variant
   2 (the timeout body isn't compiled into the receive at all);
   behaviour matches variant 2.

Implementation in `Mut.AstWalk.receive_timeout_candidates/2`: prewalk,
match `{:receive, meta, [args]}` where `args` has a non-empty `:after`
list. Skip receives without `after` (nothing to mutate; M87/M90's
ClauseDelete extension covers the `:do` message-handler clauses).

Span via `block_node_span` (receive has `:end` meta).

Opt-in via the `:receive_timeout` target.

## Acceptance

- 8 PipelineDropStage unit tests (metadata, applicability, hazard
  gating on chain length / first-stage / last-stage / nested pipes,
  rebuild semantics).
- 6 MapUpdateDrop unit tests (metadata, applicability, plain-map
  skip, multi-occurrence enumeration, base extraction).
- 7 ReceiveTimeout unit tests (metadata, applicability, no-after
  skip, three-variant emission, drop semantics).
- Full unit suite green (486 / 0); golden gates green (18 / 0).
  demo_app byte-identical — all three mutators are gated by new
  opt-in targets so the default plan emits no new candidates.
- `bin/verify` green (lint + unit + dialyzer + golden + integration
  + e2e_mut).

## Invalid + equivalent rates

Deferred to M95, which runs the full M91-expanded matrix over the
new surfaces alongside the post-M89 hazard-refined surfaces.

## Out of scope

- Pipeline-order swap (a |> f |> g vs a |> g |> f); inserting a
  stage; mutating the input expression — separate sub-shapes.
- Per-key drop from a map-update list (drop one key while keeping
  others); map-key mutations on plain literals; struct-update drops.
- Mutating the `after` timeout body (would belong to a body-statement
  mutator); message-handler clause mutations (M87/M90's ClauseDelete
  extension covers the `:do` section).
