# Env Walker vs AST Walker — Architecture Analysis

**Date:** 2026-06-03
**Question:** The env walker's goal was knowing context (`nil`/`match`/`guard`),
function-vs-module-vs-file body, and precise identification of remote calls for
replacement. How can that work reliably on a *syntactic* AST walker — without
alias/import/require understanding you can't prove `defmodule` is
`Kernel.defmodule`, and without context you can't say if code is in a guard or a
match? Is it worth unifying/refactoring the walkers?

This document is an independent code-level analysis, not a synthesis of the prior
chat. Every claim below was verified against the source.

---

## TL;DR

1. **No single walker establishes semantics. The compiler tracer does.** Precise
   remote-call identity and the real `nil`/`match`/`guard` context come from
   `Mut.Trace`, which reads `Macro.Env` *during compilation* and records
   `resolved_module/name/arity` + `env_context`. Neither `AstWalk` nor
   `EnvWalker` resolves aliases. The original agent answer was wrong to credit
   `EnvWalker` with "precise identification of remote calls" — that is the
   oracle's job.

2. **`EnvWalker` is misleadingly named. It does *not* do environment
   resolution.** `EnvSnapshot` declares `aliases`, `imports`, `requires` fields,
   but the walker **never populates them** (verified: no `:alias`/`:import`/
   `:require` handling in `descend/2`; `resolve_module_alias/2` just
   `Module.concat`s literal AST parts). `EnvWalker` is a *context + trust +
   binding-scope* walker, not a `Macro.Env` resolver.

3. **There are three trust tiers, not two walkers.** This is the real model:

   | Tier | Surfaces | Identity / context source | Reliability |
   |---|---|---|---|
   | **1 — oracle-backed** | arithmetic, comparison, boolean, unary, operators (concat/bitwise/membership), `FunctionReplace` | compiler tracer (`resolved_*` + `env_context`) | **semantically sound** |
   | **2 — tracer-proof-gated syntactic** | collection literals, pattern-position literals, variables (`VariableReplace`/`ToLiteral`) | `EnvWalker` syntactic descent, *but* `if`/`unless` trust + opaque-macro boundaries gated by tracer `macro_index` + `OpaquePolicy` | **conservative, defensible** |
   | **3 — purely syntactic** | `NegateConditional`, statement-delete, clause-delete, `Pin`, pipeline-drop, map-update-drop, receive-timeout | `AstWalk` shape/path only — **no oracle, no `macro_index`** | **assumes normal Elixir; has a real (narrow) false-positive exposure** |

4. **The user's challenge is correct — for Tier 3.** Tier 1 is semantically
   backed by the compiler. Tier 2 is gated by tracer proof for the one form that
   matters most (`if`/`unless`). **Tier 3 is the gap**: those mutators detect
   `if`/`case`/`cond`/`with` purely syntactically and never consult the oracle,
   so a shadowed special form or a user macro named like one would be mutated as
   if it were the Kernel form.

5. **Full walker unification is not worth it.** It cannot add semantic resolution
   (that stays in the oracle regardless), it's blocked by a hard stable-id
   byte-identity gate (M43), and it churns ~500–700 LOC for a dedup win the
   project already judged low-value. **The valuable, scoped move** is different:
   lift Tier 2's trust classification into Tier 3 as a *skip/cross-check layer* —
   thread the `macro_index` + opaque-macro check into the structural mutators.
   That closes the only genuine correctness gap **without** the merge and
   **without** stable-id churn. Priority: **low–medium maturation polish**, not
   urgent.

---

## How semantic facts are actually established

### The tracer is the trust anchor (`lib/mut/trace.ex`)

During the oracle compile, `Mut.Trace.trace/2` receives compiler trace events
with a live `%Macro.Env{}` and records a `%DispatchSite{}` carrying:

- `resolved_module / resolved_name / resolved_arity` — the compiler's resolved
  dispatch. **This is where alias/import/require correctness comes from.** If the
  source says `Foo.bar(x)` and `Foo` is `alias`ed to `Real.Mod`, the tracer
  records `resolved_module: Real.Mod` because the *compiler* resolved it.
- `env_context` — `nil | :match | :guard`, **straight from `Macro.Env`**. This
  is the real, semantic guard/match/body context.
- `module`, `function`, `dispatch_kind` (`remote/local/imported` ×
  `function/macro`).

`Mut.Match.attach/3` (`lib/mut/match.ex`) then binds a syntactic `AstCandidate`
to its `DispatchSite` by position + `syntactic_name == resolved_name` +
`syntactic_arity == resolved_arity`. The candidate is just a *span finder*; the
oracle supplies identity. `FunctionReplace`'s "precise remote-call" requirement
is satisfied **here**, not in any walker.

> **Correction to the original agent answer.** It said `EnvWalker` provides
> "precise identification of remote calls for replacement." It does not —
> `FunctionReplace` is a `[:dispatch]`-target mutator fed by `AstWalk` candidates
> matched against the **tracer oracle**. `EnvWalker` is never in that path.

### What `EnvWalker` actually computes (`lib/mut/env_walker.ex`)

`EnvWalker` is a hand-rolled recursive descent (`descend/2`) that tracks:

- `scope` — `:top_level | :module_body | :function_head | :function_body |
  :attr_value | :macro_definition | :quote | :opaque_macro`
- `context` — `nil | :match | :guard` — computed **syntactically** by descent
  (e.g. entering a `when` sets `:guard`, a clause head sets `:match`).
- `trust_level` — `:trusted | :opaque | :untrusted_descendant | :quoted |
  :generated`
- `bound_vars` — binding scope for the variable mutators (M54)
- quote / codegen / bitstring exclusion state

It does **not** resolve modules. `EnvSnapshot.aliases/imports/requires` are
declared (`lib/mut/env_snapshot.ex:71-73`) and **defaulted empty and never
written**. `resolve_module_alias/2` (env_walker.ex:1351) is:

```elixir
defp resolve_module_alias({:__aliases__, _meta, parts}, _current), do: Module.concat(parts)
defp resolve_module_alias(_, current), do: current
```

i.e. `Foo.Bar` → `Foo.Bar` syntactically, with no alias table. So the
`EnvSnapshot` env fields are **dead structure** — a vestige of the M39 design
sketch that was never wired (M39 explicitly *forbade* the `Macro.Env` resolver
internals it would have needed).

> **Confirmation of the GPT thread's second answer.** Its claim that
> "`EnvSnapshot` has `aliases/imports/requires` but the implementation does not
> populate or use real alias/import/require state" is **correct**. `EnvWalker` is
> a context/trust walker, not a resolver.

### The one place `EnvWalker` *is* semantically anchored: `if`/`unless`

`OpaquePolicy` (`lib/mut/opaque_policy.ex`) is binding (per M39): the walker does
**not** expand user macros, and `if`/`unless` are trusted **only with
tracer-oracle proof** via `trusted_kernel_control_flow?/3`, which consults the
`macro_index` — a map built from the tracer's macro-dispatch events
(`Mut.EnvOracle.build_macro_index/1`). Every other "special form"
(`case/cond/with/for/receive/try/fn/def*/alias/require/import`) is trusted
**syntactically** from a static `@known_special_forms` table. Opaque-macro call
sites (`:local_macro`/`:remote_macro`/`:imported_macro` not in the table, `use`,
unknown `do`-block calls) get `:opaque`, descendants `:untrusted_descendant`, and
mutators reject both.

So Tier 2 answers the user's "how do you know `if` is `Kernel.if`?" honestly:
**it requires the compiler to have said so.** That's the rigor the user is asking
for — and it exists, but only for the env-walker surfaces.

---

## The real gap: Tier 3 has no oracle proof

This is the finding that neither the original answer nor the GPT thread pinned
down precisely. The tracer `macro_index` is threaded into:

- `env_walker_candidates/4` (orchestrator.ex:130) — collections, pattern literals
- `variable_candidates/4` (orchestrator.ex:485) — variables

It is **not** threaded into the structural mutator passes:

- `conditional_results` → `AstWalk.conditional_candidates/2` matches
  `name in [:if, :unless]` **syntactically** (ast_walk.ex:172), no `macro_index`,
  no oracle.
- `statement_delete_results`, `clause_delete_results`, `pattern_shape_results`
  (`Pin`), `pipeline_drop`, `map_update_drop`, `receive_timeout` — all
  `AstWalk`-only, shape/path based.

**Consequence.** A project that shadows a special form — `import Kernel,
except: [if: 2]` plus a custom `if` macro, a `case`-shaped DSL, a locally
re-`def`ined name — would have those nodes mutated by the Tier-3 mutators as
though they were the Kernel forms. `NegateConditional` would negate a *user
macro's* first argument; `ClauseDelete` would delete a "clause" from a DSL block.
The env-walker path would correctly mark such a site `:opaque` and skip it; the
structural path does not get the chance.

**How bad is it in practice?** Narrow:

- Special-form shadowing is rare in real Elixir.
- All Tier-3 mutators are **opt-in** (none default-on) and **hazard-gated**.
- A bad mutant is usually *invalid* (compile error → discarded) or *killed*, not
  a silently-wrong survivor — so the trust damage is bounded.

But it is a genuine asymmetry: the project holds dispatch mutation to a
compiler-proof standard and structural mutation to a syntactic-assumption
standard, and nothing documents or measures that line. The user is right to call
it out.

---

## What unifying on the env walker would gain — honestly

Stating the upside plainly, then discounting it:

- **One context/trust model for every candidate.** Today only env-walker
  candidates carry `scope/context/trust_level/bound_vars`. Dispatch and
  structural candidates carry only spans/paths. Unifying would let *every*
  mutator see "am I in body/match/guard/quote/opaque/generated?".
- **Closes the Tier-3 gap.** Structural mutators would inherit opaque-macro
  skipping and `if`/`unless` tracer proof.
- **Less classifier drift.** `AstWalk.body_position?/1` and `EnvWalker`'s scope
  descent are parallel reimplementations of "is this a function body?".
- **Cheaper future env-sensitive mutators.** No re-deriving "is this
  body/match/guard/module/quote/generated".
- **Fewer parses/traversals.** Several `AstWalk` passes + a marked-literal parse
  + an `EnvWalker` literal-encoder parse run per file.

**But none of these is a semantic-resolution gain.** Unifying the walkers does
*not* give you alias/import/require resolution — that lives in the tracer oracle
and **must stay there** (a host-side walker cannot out-resolve the compiler, and
M39 forbade the `Macro.Env` internals a real resolver would need). The gains are
**consistency and maintenance**, not capability. The plan-generation speedup is
real but, per M43/M51, dominated by worker/test wall-clock — not a headline.

---

## Why the *full* merge is not worth it

1. **Hard stable-id byte-identity gate (M43, `docs/decisions/M43_envwalker_consolidation.md`).**
   `AstWalk` bakes positional `ast_path_hash` into stable IDs; env-walker
   literals key on a byte-span/`[]`-path policy. A single shared traversal must
   pick one path encoding and would churn every existing mutant's identity.
   M43's spike proved the gate **cannot** be met by making `EnvWalker` the sole
   source. The only viable direction is **`AstWalk` absorbing `EnvWalker`'s
   trust/context logic while keeping `AstWalk` paths** — and even that must
   reproduce the opaque-macro trust descent on `AstWalk` frames against the gate.

   > **Correction to the original agent answer**, which framed the deferred work
   > as "merge into EnvWalker." The decision doc's viable direction is the
   > reverse: AstWalk absorbs EnvWalker's context/trust.

2. **~500–700 LOC churn, low payoff** (M43/M51 estimate), reproducing the trust
   classifier against a correctness gate — for dedup, not a feature.
3. **No maintenance trigger has fired.** The backlog gates revisiting on "a 3rd
   literal-encoder consumer, measurable dual-walker cost, or a bug." None has.

---

## Recommendation

> **Status (2026-06-03): the scoped move + dead-field cleanup are DONE.**
> - **#1 (partial) implemented** — the structural **conditional** pass
>   (`NegateConditional`) now gates its `if`/`unless` candidates on the same
>   tracer proof the env-walker path uses: `OpaquePolicy.kernel_control_flow_proven?/3`
>   (the snapshot-free core of `trusted_kernel_control_flow?/3`). Unproven
>   (shadowed) sites are skipped as `:opaque_control_flow`. Verified end-to-end:
>   a real `Kernel.if` → mutated; an `import Kernel, except: [if: 2]` shadow →
>   skipped. Pure post-filter — surviving candidates keep their stable IDs, no
>   migration, default plan byte-identical (conditional is opt-in). The macro
>   index is now also built when `:conditional` is enabled. The other Tier-3
>   forms (`case`/`cond`/`with`/`receive`/`try`, `Pin`, pipeline, map-update)
>   target **special forms**, which have no macro-dispatch tracer event, so the
>   `macro_index` proof does not apply to them — closing their (narrower) gap
>   needs the env-walker trust *descent* (#2), still future work.
> - **#3 done** — the dead `EnvSnapshot.aliases/imports/requires` fields are
>   deleted; the moduledoc now states plainly that resolution is the tracer
>   oracle's job and the snapshot carries context/trust/binding-scope only.
> - **#2 (attach `EnvSnapshot`/trust to *all* candidates)** remains future work.

**Do not do the full walker unification.** It's blocked, churny, and adds no
capability. The two-walker split is intentional and defensible.

**Do consider the scoped, valuable refactor — but as correctness, not
unification:** make the Tier-2 trust classification available to Tier-3 as a
*skip / cross-check layer*. Concretely, lowest-risk first:

1. **Thread `macro_index` into the structural passes** (`conditional`,
   `clause_delete`, `statement_delete`, `pin`, `pipeline`, …). Where a structural
   mutator targets a Kernel-control-flow form (`if`/`unless` at minimum), require
   the same `OpaquePolicy.trusted_kernel_control_flow?/3` proof the env-walker
   path already requires. Skip (don't emit) on opaque/unproven sites. This is
   additive: it can only *remove* candidates, so it tightens trust without
   touching existing stable IDs of *surviving* candidates — **no migration**, as
   long as the gate is a pure post-filter.
2. **Attach an `EnvSnapshot` (or a trimmed `trust_level/context`) to *all*
   candidates** as a cross-check field, used initially only for skip decisions
   and richer skip-reason reporting (`:opaque`/`:untrusted`/`:generated`), not
   for identity. Validate with the existing stable-id diff harness that no
   surviving candidate's ID moves.
3. **Delete the dead `EnvSnapshot.aliases/imports/requires` fields** (or document
   them as reserved) — they advertise a resolver capability the code doesn't
   have and mislead exactly the way the original agent answer was misled.

**Priority: low–medium.** This is maturation polish on an opt-in, hazard-gated
surface with a narrow exposure — not a feature and not urgent. The right trigger
to actually do it: (a) adding another structural/env-sensitive mutator (pay the
trust-model cost once, reuse it), or (b) a real shadowing/false-positive bug
surfacing on a target. Absent either, the documented honest statement is enough:
*dispatch mutation is compiler-proven; structural mutation is syntactic and
conservatively gated; the env walker supplies context/trust (not resolution),
and resolution is and remains the tracer oracle's job.*

---

## Corrections ledger

- **Original agent answer** — wrong that "both run on every file" (`EnvWalker` is
  target-gated: literals under `:env_walker`/`:pattern_literal`/graduated-pattern,
  variables under `:variable`; orchestrator.ex:124-131,147). Wrong that
  `EnvWalker` does "precise identification of remote calls" (that's the tracer
  oracle). Missed that `EnvSnapshot.aliases/imports/requires` are never populated.
- **GPT first answer** — correct on target-gating and on the "AstWalk absorbs
  EnvWalker" direction; fair overall.
- **GPT second answer** — substantially correct: oracle is the dispatch trust
  anchor, `EnvWalker` is not a resolver, env fields unpopulated. This analysis
  confirms it and adds the precise locus of the gap (the `macro_index` reaches
  Tier-2 env-walker surfaces but **not** the Tier-3 `AstWalk` structural
  mutators) and the additive, no-migration fix path.
</content>
</invoke>
