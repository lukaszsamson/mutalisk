# Mutalisk Implementation Plan

This plan turns `ELIXIR_MUTATION_TESTING_SPEC.md` into milestones that can be executed by subagents one at a time. Each milestone is self-contained: it lists inputs, deliverables, the verification gate the agent must clear, and explicit out-of-scope items. The verification harness grows with the work — early milestones gate on tests + lint + review; later milestones gate on running real mutation testing against a fixture Mix app.

The library namespace is `Mutalisk` for the Elixir module tree but the SPEC names the public modules under `Mut.*` (e.g. `Mut.Oracle`, `Mut.Runtime`). We follow the SPEC names for public types and the runtime persistent-term key. Internal modules live under `Mutalisk.*`. Tests use the SPEC names for the public API.

## Conventions for every milestone

- Read this PLAN.md and the SPEC before starting. Do not deviate from the SPEC; if a gap is found, stop and surface it rather than inventing behavior.
- All code passes `bin/verify` (defined in M0). A milestone is not done until `bin/verify` is green at the new scope.
- All public modules carry typespecs and a one-line `@moduledoc` (no narrative docstrings).
- No comments unless they explain a non-obvious WHY.
- Never modify the user's real source tree or `_build`. All build/test work for target projects happens in working copies under `tmp/` or under explicit `MIX_BUILD_PATH` overrides applied to working copies.
- Each milestone produces a small commit-ready diff. Subagents should not merge milestones.

## Operational Contracts

These two contracts are foundational. Every milestone that spawns a child Mix process MUST honor them.

### Child-Process Bootstrap Contract

Compiler tracer options and module loading do not cross OS process boundaries. Mutalisk must explicitly load its own modules and configure the tracer in any child Mix process it drives (oracle compile, schema compile, fallback recompile, worker `mix test`).

The contract:

1. **Working-copy injection.** Mutalisk never operates on the user's source tree. It produces a working copy at `tmp/mut_work/<run_id>/` (oracle and schema phases) or `tmp/mut_sandboxes/<run_id>/<n>/` (workers). The working copy is rooted at the user project's `mix.exs`.
2. **`mix.exs` overlay.** Mutalisk writes a sibling `mix_mut.exs` into the working copy that:
   - Imports the original `mix.exs` definitions if possible, or wraps them.
   - Adds `mutalisk` as a `:path` dependency pointing to the absolute path of the host mutalisk checkout.
   - Adds `:compilers` registration for `:mut_bootstrap` ahead of `:elixir` (oracle path) or registers no extra compiler (schema path).
   - The original `mix.exs` is renamed to `mix_user.exs`; `mix_mut.exs` is renamed to `mix.exs` for the duration of the run.
3. **Bootstrap module.** `Mut.Bootstrap` is a tiny module shipped in `mutalisk` itself. It exposes:
   - `oracle_compiler/0` — a Mix compiler module (a one-shot before-`elixir` step) that calls `Code.put_compiler_option(:tracers, [Mut.Trace])` and starts `Mut.Trace.Writer`. Registered only in oracle builds.
   - `runtime_init/0` — sets up `:persistent_term` from the `MUT_ACTIVE` env var. Registered as an `application: [mod: ...]` callback only in schema/fallback builds.
4. **Worker bootstrap.** Workers run via `elixir -S mix test ...` with `MUT_ACTIVE=<id>` in the environment. The schema build's overlay registers a tiny `Mut.Runtime.Boot` application module whose `start/2` reads `MUT_ACTIVE` and sets `:persistent_term`. **No `MIX_INIT`. No `--eval` injections.** Plain env-var-driven application start.
5. **Tracer event handoff.** `Mut.Trace.Writer` is a GenServer started by the oracle bootstrap before compile. All tracer callbacks send events to the writer; the writer batches and writes JSONL to `_build/mut_oracle/.mut_oracle.jsonl` with a final `{"event":"end","count":N}` sentinel. Direct file appends from concurrent tracer callbacks are forbidden — `Kernel.ParallelCompiler` runs tracer callbacks in many processes simultaneously and unsynchronized appends interleave or lose events.

This contract is implemented in M0 (stub modules) and fully wired in M2.

### Build-Path Contract

There are exactly four roles for build directories. Every command that compiles or runs tests in a target project MUST set both `MIX_ENV` and `MIX_BUILD_PATH` per this table — never omit either.

| Role | `MIX_ENV` | `MIX_BUILD_PATH` (relative to working copy root) | Purpose |
|---|---|---|---|
| Oracle build | `test` | `_build/mut_oracle` | Tracer-instrumented compile; produces oracle JSONL + baseline beams |
| Baseline test run | `test` | `_build/mut_oracle` | Pre-mutation green-baseline check; reuses the oracle build |
| Schema build | `test` | `_build/mut_schema` | Compiles schema-instrumented sources; produces beams used by all workers |
| Worker test run (schema) | `test` | `_build/mut_schema` | `mix test --no-compile` only; `MUT_ACTIVE` env var selects mutant |
| Fallback recompile | `test` | `_build/mut_schema` (per-sandbox copy) | Targeted recompile inside sandbox before its `mix test --no-compile` |
| Worker test run (fallback) | `test` | `_build/mut_schema` (per-sandbox copy) | `mix test --no-compile`; mutant pre-baked into source + beams |

Notes:

- `MIX_BUILD_PATH` is always relative to the working-copy/sandbox root, never to the user's project.
- `MIX_ENV` is always `test` in v1. The reasoning the SPEC gives for not introducing a separate env is honored.
- Worker `mix test` invocations always pass `--no-compile --no-deps-check --no-archives-check --max-failures 1` per SPEC §Phase 3.
- Fallback recompile must restore not only `.beam` files but also Mix manifest files (`compile.elixir`, `compile.elixir_scm`, etc.) from the sandbox baseline snapshot taken at sandbox checkout, otherwise the next `mix test --no-compile` may detect staleness and trigger an uncontrolled compile.

This contract is implemented incrementally — M2 (oracle row), M7 (schema row), M8 (worker schema rows), M10 (fallback rows).

## The verification harness (`bin/verify`)

A single shell entry point that the implementing agent runs to prove a milestone is done. The harness is layered; each layer is added at the milestone listed in `[layer M#]`.

| Layer | Scope | Added at |
|---|---|---|
| `lint` | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` | M0 |
| `unit` | `mix test --include unit` (excludes `:integration` and `:e2e`) | M0 |
| `dialyzer` | `mix dialyzer` (warnings-as-errors) | M1 |
| `golden_oracle` | regenerate-and-diff oracle dumps for the fixture app | M2 |
| `golden_instrument` | regenerate-and-diff instrumented source for the fixture app | M6 |
| `integration_schema` | run schema mutants in sandbox against fixture; exit 0 only if expected outcomes match | M8 |
| `integration_fallback` | run fallback mutants in sandbox against fixture | M10 |
| `e2e_mut` | `mix mut` end-to-end against fixture; assert score, counts, JSON validity | M13 |

`bin/verify [layer]` runs one named layer; `bin/verify` runs every layer that has been enabled by completed milestones. Each milestone enables exactly one new layer or none.

Integration-layer semantics (resolved):

- The integration layers always run when invoked. They do not depend on `MUT_INTEGRATION` env vars.
- `unit` excludes `:integration` and `:e2e` ExUnit tags by default.
- The integration layers invoke the fixture sandbox flow directly via dedicated mix tasks (`mix mut.test_schema`, `mix mut.test_fallback`) that bypass ExUnit tags entirely; this avoids tag-based skipping ambiguity.
- `bin/verify` (no args) runs every enabled layer in order and stops at the first failure.

Golden files live under `test/golden/`. Regeneration is gated by `MUT_REGOLD=1`; without it, divergence is a test failure.

## Fixture: `test/fixtures/demo_app`

A small standalone Mix app used as the target for golden + integration tests. It must be present from M0 onwards but its content is filled in over time.

Required structure (M0 sets up the skeleton; later milestones add code and tests):

```
test/fixtures/demo_app/
  mix.exs                          # standalone, minimal deps
  lib/
    arith.ex                       # arithmetic operators (schema targets)
    cmp.ex                         # comparison operators
    bool.ex                        # boolean operators
    guards.ex                      # functions with guards (fallback target)
    attrs.ex                       # module attributes (fallback target)
    dsl_def.ex                     # local DSL macro definition
    dsl_user.ex                    # uses dsl_def; must NOT be mutated
  test/
    arith_test.exs                 # kills most arith mutants
    cmp_test.exs
    bool_test.exs
    guards_test.exs                # weak intentionally; some mutants survive
    attrs_test.exs
    dsl_user_test.exs              # exercises DSL paths; expects all DSL-internals skipped
```

Each test file is structured so the expected mutation outcomes are documented in a header comment (e.g., "expects: 8 killed, 2 survived, 0 timeout"). The `e2e_mut` layer asserts those numbers.

The fixture is **never** opened from the host project's mix; it is a fully separate Mix app invoked via Mutalisk's working-copy + child-process pipeline. Direct `cd test/fixtures/demo_app && mix test` is permitted only for fixture self-test (M0 sanity).

---

# Milestones

## M0 — Project skeleton, harness, fixture, bootstrap stubs

**Goal:** A buildable, lint-clean, test-clean repo with a working `bin/verify`, an empty fixture demo_app, and stub modules for the bootstrap contract.

**Inputs:** Existing `mix.exs`, SPEC, this PLAN (esp. Operational Contracts).

**Deliverables:**
- `mix.exs`: deps `:credo`, `:dialyxir`, `:jason`, `:ex_doc` (dev-only). Aliases for `lint`, `harness`. Elixir requirement matches SPEC (`>= 1.17`); update from `~> 1.20-rc`.
- `.formatter.exs`, `.credo.exs` (strict, project-local opts).
- `bin/verify` shell script implementing `lint` and `unit` layers; later layers print "skipped (M# not yet implemented)".
- `test/test_helper.exs`: `ExUnit.start(exclude: [:integration, :e2e])`.
- Bootstrap stubs (compile-clean, no logic):
  - `lib/mut/runtime.ex` with `active_key/0` returning `{Mut.Runtime, :active_mutant}`.
  - `lib/mut/runtime/boot.ex` with `start/2` reading `MUT_ACTIVE` (no-op for now).
  - `lib/mut/bootstrap.ex` with `oracle_compiler/0` and `runtime_init/0` (raise "not yet implemented").
  - `lib/mut/trace.ex`, `lib/mut/trace/writer.ex`, `lib/mut/oracle.ex` as compile-clean placeholders.
  - `lib/mutalisk.ex` re-exports.
- Fixture skeleton: `test/fixtures/demo_app/{mix.exs,lib,test}` with empty modules and a single passing test per file.
- `scripts/fixture_check.sh` runs `mix deps.get && mix test` inside the fixture; invoked by `bin/verify unit`.
- `README.md`: minimal; pointer to SPEC and PLAN.

**Verification gate:** `bin/verify` runs `lint` + `unit` and exits 0. Fixture compiles and its (placeholder) tests pass.

**Out of scope:** Any logic, tracer events, mutators, working-copy materialization.

---

## M1 — Foundational types and `Mut.Runtime`

**Goal:** All structs and the persistent-term runtime helper are defined, with thorough specs and tests.

**Inputs:** SPEC §Mutant Model, §Runtime Selector, §Mutator Behaviour, §Fallback Patch Representation.

**Deliverables:**
- `Mut.Runtime`: `active_key/0`, `set_active/1`, `get_active/0`, `clear/0`. Thin `:persistent_term` wrappers.
- `Mut.Runtime.Boot`: an Application-callback module. `start/2` reads `MUT_ACTIVE` (default 0), calls `Mut.Runtime.set_active/1`, returns `{:ok, self()}`. Tested by setting env var and observing `Mut.Runtime.get_active/0`.
- `Mut.SourceSpan`: `%Mut.SourceSpan{file, start_line, start_column, end_line, end_column, start_byte, end_byte}`.
- `Mut.SourcePatch`: as in SPEC.
- `Mut.Oracle.DispatchSite`: as in SPEC.
- `Mut.Oracle.AstCandidate`: as in SPEC.
- `Mut.Context`: as in SPEC §Mutator Behaviour.
- `Mut.Mutant`: as in SPEC.
- `Mut.Mutation`: lightweight result struct returned by mutator `mutate/2`. Fields: `original_ast`, `mutated_ast`, `description`, `mutation_kind`, `guard_safe?`, optional metadata.
- `Mut.Mutator`: behaviour module exporting all callbacks named in SPEC.
- `Jason.Encoder` derivations for everything that crosses the JSONL boundary or appears in reports.

**Verification gate:** `bin/verify` (`lint` + `unit`). New `dialyzer` layer is enabled.

**Out of scope:** Logic. Pure data + persistent-term helper.

---

## M2 — Oracle build: tracer, writer, store, generated-code filter, working-copy plumbing

**Goal:** Compile a Mix project (the fixture) under the oracle build-path role using the child-process bootstrap contract; produce a serializable oracle that excludes DSL/generated code.

**Inputs:** SPEC §Phase 1, §Generated-Code Filtering, §Oracle Policy, §Source-AST To Oracle Matching (oracle index half only). Operational Contracts: Child-Process Bootstrap and Build-Path (oracle row).

**Deliverables:**
- `Mut.WorkCopy.materialize/2`: takes (user project root, run_id) and produces a working copy at `tmp/mut_work/<run_id>/`. Uses COW (`cp -Rc` on macOS, `cp -R --reflink=auto` on Linux) with plain copy fallback. Symlinks `deps/`. Does not touch the user's tree.
- `Mut.WorkCopy.install_overlay/2`: renames `mix.exs` → `mix_user.exs`, writes `mix.exs` overlay that adds `mutalisk` as a `:path` dep and registers `Mut.Bootstrap.oracle_compiler/0` in `:compilers`. The overlay must `Code.eval_file("mix_user.exs")` to fetch user defs and merge them; if the user `mix.exs` cannot be merged (unusual), fail loudly.
- `Mut.Bootstrap`:
  - `oracle_compiler/0` returns `{:mut_bootstrap, Mut.Compilers.OracleBootstrap}`. The compiler is invoked once per Mix compile cycle. It calls `Code.put_compiler_option(:tracers, [Mut.Trace])` and ensures `Mut.Trace.Writer` is started against `_build/mut_oracle/.mut_oracle.jsonl`. It produces no artifacts; it returns `{:noop, []}` to Mix.
  - `runtime_init/0` is the application callback wiring (used in M7+).
- `Mut.Trace`: implements all SPEC tracer events. Filters per SPEC §Generated-Code Filtering. Sends each accepted event as a `%DispatchSite{}` to `Mut.Trace.Writer` via `cast`.
- `Mut.Trace.Writer`: GenServer. Buffered async writes to JSONL; `flush/0` and `close_with_count/0` callable from the bootstrap compiler at compile end. Concurrent calls from parallel-compile worker processes are serialized by the GenServer mailbox. Writes a final `{"event":"end","count":N}` sentinel; readers fail if sentinel missing.
- `Mut.Oracle`: Agent/ETS store with `start_link/1`, `put_site/1`, `lookup_by_key/1`, `lookup_by_file_line/2`, `dump_json/1`, `load_jsonl/1` (validates sentinel + count). Stable serialization order.
- `Mut.OracleBuild.run/2`: drives the working copy → overlay → child Mix invocation:
  ```
  System.cmd("mix", ["compile", "--force", "--no-deps-check"], 
    cd: working_copy,
    env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_oracle"}, {"MUTALISK_ROLE", "oracle"}])
  ```
  Reads back the JSONL into `Mut.Oracle`. Fails if sentinel/count don't match received-events count.
- Golden test: oracle JSON dump of the fixture; regenerate-on-demand with `MUT_REGOLD=1`.
- **Negative DSL test (mandatory):** the fixture's `dsl_def.ex` defines a macro that calls `quote location: :keep do def f, do: 1 + 2 end`. The expansion produces nodes whose `:line` and `:file` metadata point at the user file (because `location: :keep`). The test asserts these expansions are filtered: the operator `+` inside the expanded `def` does NOT appear in the oracle, because `Keyword.get(meta, :generated, false)` is `true` once we strip the `:keep` and let macro expansion run normally. If `:keep` is honored, we still drop because the expansion came from a user macro the tracer marks via the macro-call site itself; the oracle records the macro call site, not the expansion contents. Document the exact filter behavior in the test.

**Verification gate:** `bin/verify` enables `golden_oracle`. Oracle JSON for the fixture matches committed golden file. Negative DSL test passes.

**Subagent brief:** The oracle bootstrap compiler must run before `:elixir`. Validate by adding a tiny puts-and-fail in the bootstrap compiler and confirming it fires before any module compiles. The JSONL writer GenServer must outlive the compile cycle; tear it down only after Mix compile returns.

**Out of scope:** AST candidate walker, matching, mutators.

---

## M3 — Source AST candidate walker + oracle matching

**Goal:** Given a parsed source file and an oracle, produce the deterministic list of `%AstCandidate{}` matched to oracle sites, with explicit ambiguity diagnostics.

**Inputs:** SPEC §Phase 2 (parser options), §Source-AST To Oracle Matching (full algorithm).

**Deliverables:**
- `Mut.SourceParse`: thin wrapper over `Code.string_to_quoted!/2` with `columns: true, token_metadata: true, file: file`. Returns `{ast, source_text}`.
- `Mut.AstWalk.dispatch_candidates/2`: a `Macro.traverse/4` emitting `%AstCandidate{}` for dispatch-shaped nodes (binary ops, unary ops, dot calls, local calls). Each candidate has `ast_path`, `ast_path_hash` (SHA-256 of the path), and `source_span` from token metadata + source text byte offsets.
- `Mut.Match.attach/2`: implements the matching algorithm exactly as SPEC §Source-AST To Oracle Matching steps 1–7. Returns `{matched, diagnostics}`.
- Mutator-compatibility hook: `Mut.Match` consults a registry `Mut.Match.Registry`; mutators register compatibility predicates. For M3 a stub `Mut.Match.AlwaysCompatible` is used; real predicates land in M4.
- Unit tests covering: same line/col with different arities, columnless trace events, candidates with no oracle site, multiple oracle sites for the same source key.

**Verification gate:** Existing layers + `golden_oracle`. New tests under `test/match_test.exs` exercise all seven SPEC matching steps.

**Out of scope:** Mutators, instrumentation, module-attribute discovery (deferred to M5 plan generation).

---

## M4 — Schema mutators (arithmetic, comparison, boolean, unary-not)

**Goal:** Concrete v1 schema mutators producing valid mutated ASTs and compatibility predicates for matching.

**Inputs:** SPEC §Mutator Behaviour, §v1 Mutator Set (schema mutators only).

**Deliverables:**
- `Mut.Mutator.Arithmetic`: targets `Kernel.+/2,-,*,/`, `:erlang.+/2,-,*,/,div,rem`.
- `Mut.Mutator.ComparisonBoundary` (`<` ↔ `<=`, `>` ↔ `>=`).
- `Mut.Mutator.ComparisonNegation` (`>` ↔ `<=`, `==` ↔ `!=`, etc.).
- `Mut.Mutator.Boolean`: targets `and`, `or`, `&&`, `||` when oracle confirms dispatch resolves to the macro/operator.
- `Mut.Mutator.UnaryNot`: targets `Kernel.not/1` and `!`.
- Each implements `applicable?/2`, `mutate/2`, `equivalent?/1`, `targets/0` plus `compatible?/2` for `Mut.Match.Registry`.
- Per-mutator unit tests; golden mutation lists for fixture `arith.ex`, `cmp.ex`, `bool.ex`.

**Verification gate:** Existing layers. Mutator unit tests + fixture golden mutation lists pass.

**Out of scope:** Module-attribute discovery, schema placement, function-call deletion, return-value replacement.

---

## M5 — Stable IDs, Plan generation, Orchestrator, fallback AST discovery

**Goal:** Build the full mutation plan: walk every source file, discover schema candidates (M3+M4) AND fallback candidates (module attributes, guard expressions), route each to schema/fallback/skip with explicit reasons, assign stable IDs and integer IDs deterministically. The plan is the single artifact consumed by every later milestone.

**Inputs:** SPEC §Stable IDs, §Mutator Behaviour, §Fallback Engine (categories), §Compile-Error Rollback (mutant-id metadata format).

**Deliverables:**

- `Mut.AstWalk.attribute_candidates/2`: separate walker that finds `@attr value` definitions in module bodies. Produces `%AstCandidate{}` records with `dispatch_kind: :module_attribute`, no oracle site required, `source_span` derived from token metadata. These never go through `Mut.Match`.
- `Mut.AstWalk.guard_candidates/2`: separate walker that finds expressions inside `when` clauses of `def`/`defp`/`defmacro`/`defmacrop`/`fn`/`case`/case`-`with`. Produces `%AstCandidate{}` with `env_context: :guard` (set syntactically here; the SPEC permits this because guards are recognizable by AST shape regardless of macro expansion in v1 since we only walk user source). Guard candidates are still consulted against the oracle for dispatch classification within the guard expression where applicable; the orchestrator handles routing.
- `Mut.StableId.compute/1`: SHA-256 over the SPEC-defined input. Returns hex-encoded 128-bit ID.
- `Mut.Plan`:
  ```elixir
  %Mut.Plan{
    schema: [%Mut.Mutant{engine: :schema, ...}],
    fallback: [%Mut.Mutant{engine: :fallback, ...}],
    skipped: [%{candidate: ..., reason: atom(), detail: term()}]
  }
  ```
  Mutants in `:schema` and `:fallback` carry both `stable_id` and integer `id`. Integer IDs are assigned by sorting all mutants (schema + fallback, single global pool) by stable ID, then numbering from `1`. Mutant `0` is reserved for "original."
- `Mut.Orchestrator.plan/2`: takes `(working_copy_root, oracle)`, walks every source file, calls all enabled mutators, applies routing rules:
  - Dispatch candidate matched to an oracle site, mutator says applicable, body context (`env_context == nil`), expression position → `:schema`.
  - Dispatch candidate inside a guard, mutator says applicable, declares guard-safe replacements → `:fallback`.
  - Module-attribute candidate, attribute mutator enabled → `:fallback`.
  - Anything else with a reason atom → `:skipped`.
- Skip reason taxonomy (closed set in v1):
  - `:no_applicable_mutator`
  - `:missing_oracle_site`
  - `:ambiguous_oracle_match`
  - `:unsupported_dispatch`
  - `:unsupported_context` (pattern, quote, module body without attribute mutator)
  - `:dsl_or_generated`
  - `:guard_engine_disabled` (when guard mutators are off)
  - `:attribute_engine_disabled`
- Plan is serializable to JSON for debugging via `Mut.Plan.dump_json/1`.
- Tests:
  - Idempotency: produce the plan twice in different orders/runs; assert stable IDs identical and integer IDs deterministic.
  - Routing: a constructed file with one of each category yields one mutant per route plus expected skip reasons.

**Verification gate:** Existing layers. New tests in `test/plan_test.exs`.

**Out of scope:** Schema source rendering (M6), worker execution (M8), fallback recompile (M10).

---

## M6 — `Mut.SchemaPlacer` + golden instrumentation

**Goal:** Inject `case`-gate schemata at expression positions with hygienic variables; emit instrumented sources that compile and behave as the original when mutant id = 0. Consumes the integer mutant IDs assigned in M5.

**Inputs:** SPEC §Phase 2 (case schema, hoisting, hygiene, injection rules). M5's `%Mut.Plan{}`.

**Deliverables:**
- `Mut.SchemaPlacer.place/2`: takes `(original AST, list of plan.schema mutants attached to this file)` and returns the instrumented AST. Uses `Macro.unique_var/2` for the hoisted variable.
- Hoist policy: hoist once per `def`/`defp` body when ≥ 2 mutants live in that body; otherwise inline `:persistent_term.get(Mut.Runtime.active_key(), 0)`.
- Generated nodes carry `[mut_schema?: true, mut_ids: [...], generated: true]` meta.
- Instrumented file rendered with the formatter for golden diff stability.
- `case` arms reference the M5 integer IDs directly: `123 -> mutated_expr_a`.
- Round-trip test:
  1. Plan a fixture file → place → render.
  2. Compile rendered source via `Code.compile_string/2` in-process.
  3. With `Mut.Runtime.set_active(0)`, call public functions and assert original behavior.
  4. With each known integer mutant id, call public functions and assert mutated behavior.
- Refusal taxonomy: same skip reasons as M5; placer raises if asked to inject in a refused context (defensive, since orchestrator should have routed those to fallback or skip).

**Verification gate:** `bin/verify` enables `golden_instrument`. Golden file: instrumented `arith.ex`, `cmp.ex`, `bool.ex`. Round-trip behavior test passes for ≥ 8 mutants.

**Out of scope:** Whole-project compile, rollback, sandbox.

---

## M7 — Schema build pipeline + compile-error rollback

**Goal:** Apply the placer to every file in a working copy of a target Mix project, compile under the schema build-path role using the bootstrap contract, and recover from compile errors.

**Inputs:** SPEC §Phase 2 + §Compile-Error Rollback. Operational Contracts: Child-Process Bootstrap (schema role) and Build-Path (schema row).

**Deliverables:**
- `Mut.SchemaBuild.build/2`: `(working_copy_root, plan)` → produces an instrumented build at `<working_copy>/_build/mut_schema/test`. Steps:
  1. Reuse the working copy from oracle phase or materialize a fresh one.
  2. Reinstall overlay in **schema role**: registers `Mut.Runtime.Boot` as the application start module, does NOT register the oracle bootstrap compiler. The overlay also adds `mutalisk` as a `:path` dep so `Mut.Runtime` and `Mut.Runtime.Boot` are loadable in the working copy's BEAM.
  3. Write instrumented source files over the working-copy `lib/` (and `test/` is left untouched).
  4. Run:
     ```
     System.cmd("mix", ["compile", "--force"], 
       cd: working_copy,
       env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_schema"}, {"MUTALISK_ROLE", "schema"}])
     ```
  5. Snapshot `_build/mut_schema` (recursive list of files + content hashes) for sandbox reset later.
- `Mut.CompileRollback.run/3`: parses Elixir compiler diagnostics, locates the surrounding instrumented `case` by line/col + `mut_ids` metadata, removes those mutants from the placer plan (transitions them to `:invalid` with diagnostic attached), re-renders the file, and recompiles. Honors `max_rollback_iterations: 3` and `max_invalid_mutants_per_file: max(10, ceil(file_mutants * 0.02))`.
- `Mut.Mutator.Test.AlwaysWrong` (test-only): emits non-compiling AST. Drives a rollback test asserting budgets are enforced and that good mutants survive.

**Verification gate:** Existing layers + `golden_instrument`. New rollback tests under `test/rollback_test.exs`.

**Out of scope:** Worker VMs, fallback engine, scheduling.

---

## M8 — Sandbox pool + worker (Port-driven `mix test`)

**Goal:** Run isolated `mix test` invocations inside per-worker sandbox copies of the schema build, switching the active mutant via `MUT_ACTIVE` env var (read by `Mut.Runtime.Boot` at app start).

**Inputs:** SPEC §Sandbox Model, §Phase 3, §Result Classification. Operational Contracts: Build-Path (worker schema row).

**Deliverables:**
- `Mut.Sandbox.create_pool/2`: `(schema_working_copy, concurrency)`. Creates N sandbox dirs at `tmp/mut_sandboxes/<run_id>/<n>/` via COW copy of the schema working copy (which includes `_build/mut_schema`). `deps/`, `mix.lock`, `mix.exs`, `config/` may be symlinked from the schema working copy.
- `Mut.Sandbox.checkout/1`, `checkin/1`. Each sandbox stores a baseline manifest snapshot (file list + content hashes for `_build/mut_schema` and `lib/`).
- `Mut.Sandbox.reset/1`: restores any modified `lib/` files and `_build/mut_schema` artifacts (including `.mix/compile.elixir` manifest files) from the baseline snapshot. Used after fallback runs.
- `Mut.Worker.run_schema/3`: `(sandbox, mutant_id, test_files)`. Spawns:
  ```
  Port.open({:spawn_executable, mix_path}, [
    args: ["test", "--no-compile", "--no-deps-check", "--no-archives-check", "--max-failures", "1", "--formatter", "Mut.Worker.Formatter"] ++ test_files,
    cd: sandbox,
    env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_schema"}, {"MUT_ACTIVE", to_string(mutant_id)}, {"MUTALISK_ROLE", "worker"}],
    ...
  ])
  ```
  `Mut.Runtime.Boot` (registered as the working copy's application start module by the schema overlay) reads `MUT_ACTIVE` and sets `:persistent_term`.
- `Mut.Worker.Formatter`: a custom ExUnit formatter writing structured per-test results to stdout in JSONL form for the parent to parse.
- Result classification per SPEC: `:killed | :survived | :timeout | :error`. `:invalid` comes from rollback (M7), not workers.
- Single retry for `:error` per SPEC.
- Integration test (under `mix mut.test_schema`): for each known mutant in `arith.ex`, run worker and assert killed/survived as documented.

**Verification gate:** `bin/verify` enables `integration_schema`. Golden expectation: hand-curated set of ~10 known mutant outcomes against the fixture.

**Subagent brief:** Pre-implementation, manually validate `mix test --no-compile` skips compile after a successful schema build. Validate `MUT_ACTIVE` is observed by `Mut.Runtime.Boot.start/2` by adding a temporary `IO.inspect` and confirming.

**Out of scope:** Test selection (runs all fixture tests for now), fallback engine, JSON reporter.

---

## M9 — Static test selection

**Goal:** Map each mutant to a test-file subset using SPEC's static dependency rules.

**Inputs:** SPEC §Test Selection (v1 static).

**Deliverables:**
- `Mut.TestSelection.Static`: parses test files, extracts module references (alias, import, require, `use Mod`, `@behaviour Mod`, direct `Mod.fun(...)` calls, `&Mod.fun/N` captures, `apply(LiteralMod, ...)`). Returns `%{module => MapSet.t(test_file)}`.
- Convention layer: `Foo` → `FooTest` and any test file whose path mirrors source path under `test/`.
- Dynamic-dispatch fallback: any test file using `apply(var, ...)` or `Module.concat(...)` is added to all mutants' covering set.
- Integration test: re-run M8's worker test with selection enabled; assert reduced fanout vs unfiltered; mutation outcomes unchanged.

**Verification gate:** Existing layers + `integration_schema`.

**Out of scope:** Coverage-based selection (v1.5). Incremental history (v2).

---

## M10 — Fallback engine: source patches + manifest-driven recompile

**Goal:** Run fallback mutants by patching one byte range in the sandbox source, recompiling only the affected file plus compile-connected dependents inside the sandbox, then running the targeted tests.

**Inputs:** SPEC §Fallback Engine, §Fallback Flow, §Fallback Patch Representation, §Compile-Connected Dependents. Build-Path Contract (fallback rows).

**Deliverables:**
- `Mut.FallbackPatch.render/2`: `(mutant, source_text)` → `%Mut.SourcePatch{}`. Renders only the mutated sub-expression with the formatter; computes byte-range splice. Refuses with `:missing_source_span` if the span cannot be computed precisely.
- `Mut.MixManifest.read/1`: parses `_build/mut_schema/test/lib/<app>/.mix/compile.elixir`. Tolerant of Elixir 1.17+ format variants. Exposes module-to-source and source dependency graph (compile, export, struct, runtime). Has an explicit `version_assertion/1` that fails loudly on unknown shape.
- `Mut.Recompile.dependents/2`: walks `[:compile, :struct, :export]` edges (transitive `:compile`). Ignores `:runtime`.
- `Mut.Recompile.recompile/2`: invokes the recompile **as a child Mix process inside the sandbox**, NOT via in-host `Kernel.ParallelCompiler`. Reasoning: the host BEAM does not have the target's deps loaded; calling ParallelCompiler in-host would either fail at link time or pollute the host. Implementation:
  ```
  System.cmd("mix", ["compile", "--no-deps-check", "--no-archives-check"], 
    cd: sandbox,
    env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_schema"}, {"MUTALISK_ROLE", "fallback"}])
  ```
  Mix's incremental compile honors the manifest and only rebuilds modules whose source changed. We rely on Mix's incrementality rather than computing the recompile set ourselves; `Mut.Recompile.dependents/2` is used to validate that Mix's choice matches our expectation (sanity check) and to short-circuit "no fallback needed if dependents set is empty and the patched .beam can be replaced from a pre-built per-mutant beam — deferred optimization).
  - Fallback also writes the patch to `lib/...` in the sandbox; the next `mix compile` picks it up via mtime + source-content hash.
- `Mut.Worker.run_fallback/3`: like `run_schema/3` but: (1) apply patch, (2) call `Mut.Recompile.recompile/2`, (3) `mix test --no-compile ...`, (4) call `Mut.Sandbox.reset/1` to restore source + beams + manifests.
- Tests:
  - Unit: patch `guards.ex`, run recompile against a real schema build, assert only the targeted .beam (and any compile dependents) changed mtime; reset; assert sandbox returned to clean state including manifest contents.
  - Integration (under `mix mut.test_fallback`): hand-constructed fallback mutant for `guards.ex` runs to completion with expected outcome.

**Verification gate:** `bin/verify` enables `integration_fallback`.

**Subagent brief:** Manifest format is internal. Before implementing, write a disposable script reading the manifest of three Elixir 1.17+ Mix projects (the fixture and two `tmp/` checkouts), dump shapes, pin in `Mut.MixManifest`. Manifest restoration during `Mut.Sandbox.reset/1` is mandatory — without it, the next `mix test --no-compile` may see stale dep metadata and either skip needed recompile or fail.

**Out of scope:** Fallback mutators themselves (M11). Just hand-constructed patches in tests.

---

## M11 — Fallback mutators (guards, module attributes)

**Goal:** Real fallback mutators feeding M10's engine, sourced from the M5 plan's `:fallback` bucket.

**Inputs:** SPEC §v1 Mutator Set (fallback). M5 (fallback discovery already done).

**Deliverables:**
- `Mut.Mutator.GuardComparisonBoundary`: when a comparison appears in a `when` clause, emit boundary swaps. Output discipline: mutated guard must remain guard-safe.
- `Mut.Mutator.GuardComparisonNegation`.
- `Mut.Mutator.GuardTypeTest`: swap among `is_integer`, `is_float`, `is_number`, `is_atom`, `is_binary`, `is_list`, `is_map`, `is_tuple`, etc.
- `Mut.Mutator.AttributeLiteral`: numeric/string/boolean literals in `@attr value`. Off by default in v1 config.
- Each mutator's `targets/0` returns `[:guard]` or `[:module_attribute]`; `applicable?/2` checks `engine == :fallback`.
- Integration: oracle + plan + fallback against fixture's `guards.ex` and `attrs.ex`; ≥ 5 fallback mutants with documented kill/survive expectations.

**Verification gate:** `bin/verify` (`integration_fallback`).

**Out of scope:** Pattern, literal-outside-attributes mutators.

---

## M12 — Reporters and metrics

**Goal:** Terminal report, Stryker mutation-testing-elements JSON v2, and v1 metrics block.

**Inputs:** SPEC §Reporting, §Metrics To Capture From v1.

**Deliverables:**
- `Mut.Metrics`: accumulator started by the runner; receives mutant lifecycle events; produces the report bundle.
- `Mut.Reporter.Terminal`: streaming + final summary (score, counts, surviving mutants with `file:line` + diff, fallback wall-clock %, fallback count %, skipped grouping).
- `Mut.Reporter.StrykerJson`: schema v2 output. Stable IDs in a `mutalisk` extension key. Sources embedded; statuses mapped per SPEC.
- Schema validation: schema v2 fetched once and embedded under `priv/`. Hand-rolled minimal validator suffices.
- Tests: golden Stryker JSON for the fixture run.

**Verification gate:** Existing layers; JSON-validity test under `unit`.

---

## M13 — `mix mut` task and end-to-end run

**Goal:** A user runs `mix mut` in a Mix project and gets a complete report.

**Inputs:** SPEC §Configuration, §Mix Task Flow, §Acceptance Criteria For v1.

**Deliverables:**
- `Mix.Tasks.Mut`: argv parsing, config loading, orchestrates the full pipeline:
  1. Enforce `MIX_ENV=test`.
  2. Materialize working copy.
  3. Oracle build (M2).
  4. Baseline test run (`MIX_BUILD_PATH=_build/mut_oracle`); abort on failure.
  5. Plan generation (M5).
  6. Schema build + rollback (M7).
  7. Sandbox pool + schema worker execution (M8 + M9).
  8. Fallback worker execution (M10 + M11).
  9. Reporters + metrics (M12).
  10. Exit code from threshold.
- CLI flags as in SPEC.
- Default config under `config/config.exs` of the host project; CLI overrides.
- Acceptance test (`e2e_mut` layer): runs `mix mut` against the fixture in CI, asserts:
  - JSON file written.
  - Score within ±1% of fixture's documented expected score.
  - Schema vs fallback breakdown emitted.
  - Stable IDs present and identical to a committed reference.
  - Fixture's user source tree unchanged (`git status -- test/fixtures/demo_app` clean).
- Documentation pass: `README.md` user-facing usage; SPEC and PLAN remain authoritative.

**Verification gate:** `bin/verify` runs **all layers** including `e2e_mut`. v1 acceptance gate per SPEC §Acceptance Criteria For v1.

---

## M14 — Polish, real-app smoke, doc

**Goal:** Run mutalisk against one real-ish OSS Elixir project (small library checked out into `tmp/`); capture metrics. No code changes beyond bug fixes uncovered.

**Deliverables:**
- `bench/` script that checks out and runs mutalisk against a chosen target.
- `BENCHMARKS.md` capturing the run.
- Bug fixes for issues uncovered. No new mutators.

**Verification gate:** All previous layers plus the smoke run completes without `:error`-status mutants.

---

# Risk register and mitigation per milestone

| Risk | Surfaces at | Mitigation |
|---|---|---|
| Tracer events lost or interleaved across parallel-compile workers | M2 | All events flow through `Mut.Trace.Writer` GenServer; final `{"event":"end","count":N}` sentinel; loader fails on count mismatch |
| Bootstrap compiler not invoked before `:elixir` | M2 | Pre-implementation smoke: register a print-and-fail compiler, confirm it fires first |
| `mix.exs` overlay loses user defs (custom `def project`/`application` keys) | M2/M7 | Overlay loads `mix_user.exs` via `Code.eval_file/1` and merges; merging is deep; failure to merge fails loudly |
| AST candidate matching ambiguity | M3 | Algorithm step 7: skip + diagnostic; never silent; tested with constructed collisions |
| Mutant ID stability across re-plans | M5 | SHA-256 input is SPEC-fixed; idempotency test in M5 |
| Hoist + hygiene collisions | M6 | `Macro.unique_var/2`; round-trip behavior test asserts identical results at id=0 |
| `--no-compile` not honored by `mix test` | M8 | Pre-implementation manual validation; if broken, fall back to a custom `Mix.Tasks.Mut.Worker` that calls `Mix.Tasks.Test.run/1` directly |
| `MUT_ACTIVE` not seen by `Mut.Runtime.Boot.start/2` | M8 | Validated in M8 subagent brief; bootstrap module registered as `application: [mod: ...]` in schema overlay |
| Mix manifest format changes | M10 | Version assertion; test against ≥ 2 Elixir 1.17+ patch releases in CI |
| Sandbox COW unsupported on filesystem | M8 | Detect at pool creation; fall back to `File.cp_r!` with logged warning |
| Sandbox reset misses `.mix` manifest restoration | M10 | Sandbox baseline snapshot includes `_build/mut_schema/**` recursively; reset replays full snapshot, asserted in unit tests |
| `:persistent_term` leak across mutant runs | M8 | Each mutant gets a fresh BEAM (port spawn). No worker BEAM reuse across mutants in v1 |
| Schema gate alters evaluation order in `with`/`for` | M6 | Refusal rules for non-expression positions; golden test covers `with` as scrutinee |
| DSL macro expansion preserves user line/file via `:keep` | M2 | Negative DSL test: macro expansion at user `:line` must still be filtered; tracer drops on `generated: true` and on macro-call-site recording |

# Subagent execution playbook

For each milestone, the orchestrator (you) hands a subagent:
- The milestone section verbatim.
- The Operational Contracts section verbatim.
- Pointers to the SPEC sections it cites.
- The current state of `bin/verify` and which layer it must reach.
- The fixture state (which modules exist, what tests document).

The subagent must:
- Read, then plan within the milestone's scope.
- Implement.
- Run `bin/verify` until green.
- Return a short report: files changed, layer status, anything skipped, any SPEC ambiguities encountered.

The orchestrator must:
- Verify by re-running `bin/verify`.
- Read the diff before approving.
- Refuse milestones that introduce out-of-scope work.

# Out of scope for v1 (do not let it sneak in)

- Coverage-based test selection (v1.5).
- Incremental history (v2).
- Pattern, literal (outside attributes), variable mutators (v2).
- User macro expansion in oracle (never).
- Wrapper-function guard schemata (v2 if metrics justify).
- Compiler fork (never in v1).
- BEAM bytecode mutation (never in v1).
- In-process ExUnit reruns (never).
- Function-call deletion mutator (deferred until false-positive profile is understood).
- Return-value replacement mutator (deferred until concrete variants are pinned in SPEC).
