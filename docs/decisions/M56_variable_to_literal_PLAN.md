# M56 — VariableToLiteral, the deferred M54 mutator

**Status: IMPLEMENTED (2026-05-24).** Shipped the operator-only first slice
(`:number`/`:binary`/`:list` hints; boolean deferred), hint carried on the
candidate/`Context`, opt-in via explicit `--mutators variable_to_literal`
(absent from `Defaults.list/0`). `bin/verify` green. The keep/cut equivalent-
rate measurement is the remaining open item (M55 corpus follow-up). Picks up the
`VariableToLiteral` deferral recorded in `docs/decisions/M54_variable_mutators.md`.

## Why it was deferred

M54 deferred `VariableToLiteral` because replacing a variable with a literal
needs the variable's *type* to produce useful (non-trivially-killed, non-noise)
mutants, and the env walker is syntactic — it must not expand macros or run
inference (M39 no-expansion contract). A naive "replace every variable read
with `nil`/`0`" floods the run with trivially-killed, low-signal mutants
(any test touching the line kills it) — exactly the noise M55 already flagged
for `VariableReplace` in codegen code.

Note: such mutants are **valid** (a literal is syntactically legal wherever a
value goes), so this is a *signal/noise* problem, not an invalid-rate problem.

## Core idea: syntactic use-site type hints (no expansion)

Infer a variable's *evident* type from the type-determining syntax it flows
into at the read site — observed purely from the AST, no expansion:

| syntactic context at the read | hint | boundary literal(s) |
|---|---|---|
| arithmetic operand (`+ - * / div rem`, `abs/1`) | `:number` | `0` (and optionally `1`) |
| string/binary (`<>`, `String.*`, `byte_size`, `<<v::binary>>`) | `:binary` | `""` |
| list (`++`, `--`, `[h \| v]`, `length`, `Enum.*`, `Keyword.*`) | `:list` | `[]` |
| boolean (`and`/`or`/`not`, `if v`, `unless v`) | `:boolean` | `false` |

**Gate: emit a candidate only when a definite hint is present.** No hint → no
mutant. This is the primary noise control — it restricts the surface to reads
whose intended shape is locally obvious, which is exactly where a boundary
literal is a meaningful test ("does any test pin this value's boundary?").

## Mechanism (thread a hint down the walk)

Reuse the M54 variable infrastructure (`collect_variable_candidates/2`,
`bound_vars`, the `descend` variable clause). Add a `type_hint` field threaded
in walker state:

1. In `classify_call/4` (and a small operator table), when descending a
   type-determining node, set `state.type_hint` for the operand positions only
   (e.g. `{:+, _, [a, b]}` → walk `a`, `b` with `type_hint: :number`; clear it
   for non-operand positions). Use `Map.put`/`Map.get` like the M54
   `in_bitstring` flag, so initial-state builders are untouched.
2. The hint is **shallow / single-level**: it applies to the direct operands of
   the type-determining node, not transitively. `f(x) + 1` hints `f(x)` numeric
   but NOT `x` inside `f(...)` (we don't know `f`'s return shape). This keeps it
   sound and cheap.
3. At a variable read (`maybe_emit_variable_candidate`), if `state.type_hint` is
   set, emit a `VariableToLiteral` candidate carrying the hint (alongside, or
   instead of, the `VariableReplace` candidate).

## New mutator `Mut.Mutator.VariableToLiteral`

- `targets: [:variable]` (same opt-in surface as `VariableReplace`; M55 kept
  `:variable` opt-in, so this rides the same flag — no new target).
- `applicable?`: variable read, `env_context == nil`, `engine == :fallback`,
  and `ctx` carries a type hint.
- `mutate`: hint → boundary literal(s); produce `{name,_,ctx}` → `literal`.
- Fallback-routed (literal substitution at a read is not schema-safe here; and
  it shares the `:variable` fallback path).

## Hazards & gates (beyond the hint gate)

- **equivalent?**: a `:number`→`0` swap is equivalent if the var is always `0`
  in tests; rely on standard equivalent gating + report the rate.
- **codegen/macro noise**: M55 showed variable mutation errors heavily in
  functions that build quoted code. Same risk here. Mitigation: keep opt-in;
  measure the error rate on gettext/plug in M56 validation; consider a
  module-level skip if it dominates.
- **double-emission**: a read can yield both a `VariableReplace` and a
  `VariableToLiteral` candidate — fine (distinct mutations), but cap total
  per-read mutants to bound count.

## Validation plan

- Unit: hint detection per operator class; "no hint → no candidate"; boundary
  literal per hint.
- Corpus (M55 subset): invalid (expect ~0, literals are valid), **equivalent**
  rate, kill rate, error rate (codegen), and a signal check — does
  VariableToLiteral catch mutants `VariableReplace` misses?
- Zero stable-id churn (opt-in; off by default).
- `bin/verify` green.

## Decision gate (end of M56)

Keep only if it adds catches over `VariableReplace` at an acceptable
equivalent/error rate. If the hint surface is too sparse to matter, or the
error rate mirrors `VariableReplace`'s codegen noise without added signal,
**cut it** and close the deferral as "not worth the surface."

## Review feedback incorporated (Codex, 2026-05-24)

Codex reviewed this plan and the M54/M55 deliverables. Adjustments folded in:

- **Prerequisite (now done):** the `\\` default-expression fake-binding bug in
  `pattern_vars/1` is fixed first (commit alongside this plan) — it is the same
  class as the M55 bitstring-specifier bug and would otherwise also leak into
  any VariableToLiteral candidate set.
- **Start narrower:** ship an **operator-only first slice** (`+ - * /`, `<>`,
  `++`/`--`, `and`/`or`/`not`) and skip `String.*`/`Enum.*`/`Keyword.*` call
  hints initially. This keeps the strongest no-expansion argument (direct
  syntactic operators only) while yielding enough data to decide.
- **Don't overload `bound_vars`:** carry the type hint as its own field on the
  `AstCandidate`/`Context`, not piggybacked on the variable alternative set.
- **`f(x) + 1` does NOT hint `x`** — confirmed correct: `f(x)` is the
  arithmetic operand; hinting `x` would infer through `f/1`'s return type,
  violating no-expansion. Single-level/shallow is right.
- **Equivalent-rate is a keep/cut METRIC, not a detail:** boundary literals
  (`0`, `false`, `[]`, `""`) are frequently equivalent when tests already
  exercise boundary inputs. Measure it first-class; cut if high.
- **Rollout:** do not silently broaden `--enable variable` for users who opted
  into VariableReplace. Either gate VariableToLiteral behind explicit
  `--mutators variable_to_literal`, or exclude it from the default mutator list
  even when `:variable` is enabled, until its keep/cut gate passes.

## Effort / risk

Medium. The hint-threading is new but localized to `classify_call` + a small
operator table; the mutator and candidate path reuse M54. Main risk is sparse
hint coverage (low yield) or equivalent-rate noise — both measured before
committing to keep.
