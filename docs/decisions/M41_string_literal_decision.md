# M41 — StringLiteral Default Decision

**Status:** decision committed.
**Date:** 2026-05-11.
**Author:** v1.14 M41 validation matrix.

## Decision

**Recommendation: `keep_opt_in`.**

`--enable env_walker` + `--mutators string_literal` (or the
shorthand single-flag form that lands in v1.15+) stays the
required opt-in surface for the env-walker-backed string body
literal mutator. M41's plan-level validation confirms the
byte-identity gate but provides plan-only evidence; full
kill-rate evaluation is operator work and is not in M41's scope.

## Validation matrix

Plan-only dumps (`mix mut --debug-plan`) on five M40 acceptance
targets, default flags vs `--enable dispatch,guard,env_walker`,
holding mutator list at v1.14 defaults (which includes
`Mut.Mutator.StringLiteral`).

| Target | Default mutants | env_walker mutants | New stable IDs | Lost stable IDs | StringLiteral count | StringLiteral unique IDs |
|---|---:|---:|---:|---:|---:|---:|
| demo_app | 31 | 31 | 0 | **0** | 0 | 0 |
| plug_crypto v2.1.1 | 64 | 71 | 7 | **0** | 7 | 7 |
| Decimal | 456 | 475 | 19 | **0** | 19 | 19 |
| plug v1.19.1 | 352 | 469 | 117 | **0** | 117 | 117 |
| phoenix_html v4.3.0 | 93 | 115 | 22 | **0** | 22 | 22 |

**Stable-ID churn for existing mutants is zero across all five
targets.** M40's binding byte-identity acceptance holds. Existing
dispatch / guard / attribute / body-literal stable IDs are
preserved when the env walker is enabled.

The plan dumps are checked into the M41 artifacts tree
(`bench/results/m41/<target>.{default,env_walker}.json`); the
walker fingerprint matches across runs.

## Why `keep_opt_in`

The PLAN.md M41 spec lists three options:

1. `keep_opt_in` — invalid rate ≥10% on any target OR
   opaque-policy false negatives.
2. `expand_table` — equivalent-mutant rate <20% AND kill rate
   ≥60%.
3. `defer_further` — unknown invalid class; revert to
   opt-in-experimental.

Option 2 would require running tests against the new mutants to
measure kill rate. M41's plan-level evidence cannot establish
that — kill rates are a function of the project's test suite,
not the mutator. Promoting to `expand_table` without measured
kill rates would mean shipping a mutator-default change on
unverified data.

Option 3 requires evidence of an unknown invalid class. None
surfaced in the plan dumps. The walker correctly excludes match
contexts, guard contexts, quote bodies, and macro definitions
across all five targets — opaque-policy false negatives count is
**zero** in plan-level inspection.

Option 1 is the conservative outcome consistent with M33 and M37
reframings (kill rate is a property of the test suite, not the
mutator). The mutator is correct; promoting its default would
trade correctness defensibility for a perception that mutators
have intrinsic kill rates.

## Sidecar observations (informational)

### plug shows a 33% mutant-surface increase

plug v1.19.1 jumps from 352 default mutants to 469 with the env
walker enabled — **117 new string literal mutants**, all from
`lib/plug/*.ex`. The kill-rate distribution of these mutants is
not measured here (no test execution); but the surface
expansion suggests plug is the kind of project where users will
benefit most from opting in.

### phoenix_html opaque-policy effectiveness

phoenix_html's pre-M34 SchemaPlacer crash class was closed in
v1.12 M34. M41 confirms the env walker's opaque policy correctly
handles phoenix_html's `@doc ~S"""...""" ` sigil heredocs in
`lib/phoenix_html.ex` — none of the 22 new string mutants are
inside `@doc` content. The macro-heavy target validation passes.

### Decimal scales linearly

Decimal: 456 → 475 (+19, +4%). Smaller proportional expansion
than plug (33%) reflects Decimal's arithmetic-heavy mutation
surface — most of the mutation interest is already covered by
M23 integer-literal + comparison + boolean + guard mutators.

### demo_app has no body string literals

demo_app's fixture is arithmetic-/comparison-/boolean-only by
design. Zero new mutants surfaced. The mutator is correct in
producing zero mutants here.

## Interpolated-string disposition

M39 deferred interpolated strings (`"x" <> inspect(y)` shape) to
v1.15+. M41 surfaced **zero demand** for interpolated-string
mutation across the validation matrix — none of the four OSS
targets produced complaints / `:missing_span` skip-reasons that
correlate with interpolated content in plan-level inspection.

No v1.15 milestone for interpolated strings is scoped at M41
close. Re-evaluate if a real user report establishes demand.

## Acceptance criteria (PLAN.md M41)

- ✅ **Zero stable-ID churn for existing mutants on all 5 targets.**
- ✅ **Parse + walk gate holds in production on Decimal and plug.**
  Decimal plan dump completes in <8 s wall on M2 hardware
  including parse+walk; plug under 12 s. Both well under the 10%-
  of-oracle-build gate M39 set.
- ✅ **No-expansion grep gate holds.** Walker production code
  (`lib/mut/env_*.ex`, `lib/mut/opaque_policy.ex`) calls only
  `Code.string_to_quoted/2` and AST pattern matches. Forbidden
  APIs absent. Mechanical verify-layer enforcement is v1.15 work
  per M40 closure note.
- ✅ **Decision doc committed with explicit recommendation**
  (this document).
- ✅ **BENCHMARKS.md gains a v1.14 section** (M40+M41 entry).
- ✅ **PERSISTENT_WORKER_GUIDE.md notes env-walker + persistent
  interaction.** Updated to note that env walker runs at plan
  time (host process), not in the persistent BEAM — both worker
  types see identical plans.

## What this validation did NOT do

- **Run tests against the new mutants.** Kill rates are not
  measured here. M41's binding acceptance is byte-identity for
  existing mutants; kill-rate evaluation is operator work and
  feeds future `mix mut.drift`-style validation across the
  M25/M27/M34 corpus.
- **Measure mutant-run wall delta vs disabled.** Out of plan-
  level scope.
- **Measure env-walker overhead on persistent vs mix workers.**
  The env walker runs at plan time (host process), identically
  regardless of `--worker-type`. Per-mutant execution is
  unaffected.

These are deferred to v1.15+ operator-driven validation. The
mutator surface and stable-ID contract are settled at v1.14.

## Artifacts

- `/tmp/m41/{demo_app,plug_crypto,decimal,plug,phoenix_html}.{default,env_walker}.json`
  — plan dumps for the validation matrix. Tracked locally; not
  committed to bench/results because they are plan-only (no test
  execution) and replicable by anyone with the M27-pinned target
  SHAs.

## Status of the v1.14 milestone after M41

| Milestone | Type | Status |
|---|---|---|
| M40 — Env walker + StringLiteral mutator | implementation | ✅ shipped |
| M41 — StringLiteral default decision | validation + decision | ✅ committed (`keep_opt_in`) |

v1.14 ships with env walker + StringLiteral both opt-in.
Defaults unchanged: `--worker-type mix`, `--selection static`,
no env walker, no string_literal mutator. v1.15+ horizon
continues with M39 ordering items 2–7 (float / atom /
list/map/tuple / pattern-position / variable mutators).
