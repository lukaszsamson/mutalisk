# M90 — New mutators: GuardBoolean + Receive/try ClauseDelete (v1.25)

**Date:** 2026-05-28

Two new opt-in mutators closing the real remaining v1 catalogue gaps.
M93 decides graduation.

## `Mut.Mutator.GuardBoolean`

The existing `Guard*` family covers comparison operators
(`GuardComparisonBoundary`, `GuardComparisonNegation`) and type-test
predicates (`GuardTypeTest`); the boolean connectives inside `when`
guards were the small remaining gap. GuardBoolean fills it:

- `and` <-> `or` (the strict, guard-safe forms — `&&`/`||` aren't allowed
  in guards, so they're handled by `Boolean` in body position only).
- `not x` -> `x` (drop the negation; flips guard polarity).

**Target choice — `:guard_boolean`, not `:guard`.** Adding GuardBoolean
with target `:guard` would make it fire on every default-on plan
(`:guard` is in `@default_enabled_targets`), since the orchestrator's
guard pathway filters mutators by their declared target only. The
demo_app golden plan immediately broke (`is_integer(x) and x > 0` in
`Guards.positive?/1` produced an extra `and`<->`or` candidate). The
standard opt-in pattern — use a new target so the default plan keeps
the existing surface — required a dedicated `:guard_boolean` target,
wired into the orchestrator's `guard_fallback_results/4` as a companion
that joins `guard_mutators` only when `:guard_boolean in
enabled_targets`. Same env_context (`:guard`), same walker, separate
gate.

CLI: `--enable guard_boolean` activates the target; `--mutators
guard_boolean` resolves the module.

## `Mut.Mutator.ClauseDelete` — receive/try extension

M87 covered `case` / `cond` / `with`; M90 extends to `receive` and
`try`. Same hazard framework, same fallback routing, same `:clause_delete`
opt-in target — only the construct-rebuild logic and the per-construct
last-clause/single-clause exclusion are new.

**`receive`**. `{:receive, meta, [[do: clauses, after: ...]]}`. Mutate
the `:do` clauses only (the message-handler arms); `after:` is a
single-statement timeout body, not a clause list. Hazards: skip last
clause, skip single-clause receives. Section tag `:receive_do`.

**`try`**. `{:try, meta, [[do: body, rescue: clauses, catch: clauses,
else: clauses, after: body]]}`. Each clause section (`:rescue`,
`:catch`, `:else`) is mutated independently with the same per-section
last-clause + ≥2-clause discipline. `:after` is a single body, not
touched. Section tags `:try_rescue` / `:try_catch` / `:try_else`.

M89's `error_only_clause?` hazard applies uniformly to all sections —
clauses whose body is a pure `raise`/`throw`/`exit` are excluded from
the candidate pool (the "shouldn't-happen" arm class).

## Acceptance

- GuardBoolean: 7 unit tests pass (metadata, applicability,
  and/or/not mutations, compatibility).
- ClauseDelete: 19 unit tests pass — covers original case/cond/with +
  M89 error-only hazard + new M90 receive/try sections including
  per-section last-clause exclusion.
- Golden gates green (18 tests) — zero stable-id churn on demo_app.
  The receive/try extension finds no candidates in demo_app (no
  receive/try constructs); GuardBoolean is target-gated to opt-in so
  it doesn't fire on the default plan even though demo_app has guard
  `and`.
- Full `bin/verify` green (unit + dialyzer + lint + golden + integration
  + e2e_mut).

## Invalid + equivalent rates

Deferred to M93, which runs the matrix over GuardBoolean + the new
receive/try ClauseDelete surface and applies the M62 gate.

## Out of scope

- `xor` (rarely used in guards; no clean semantic swap).
- `&&`/`||` (not guard-safe; handled by `Mut.Mutator.Boolean` in body
  position only).
- `receive` `after:` timeout mutation (single-statement, not a clause
  shape).
- `try` `:after` cleanup mutation (single body, not a clause shape).
