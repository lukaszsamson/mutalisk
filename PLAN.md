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
2. **`mix.exs` overlay.** Mutalisk writes a replacement `mix.exs` into the working copy that:
   - Renames the original `mix.exs` to `mix_user.exs` (preserved verbatim).
   - `Code.require_file/2`s `mix_user.exs` so the user's `MyApp.MixProject` is defined and pushed via `use Mix.Project`.
   - Captures the user module via `Mix.Project.get!()`, pops the user project from Mix's project stack, and stashes the module through `Application.put_env/3`.
   - Defines `Mutalisk.WrappedMixProject` which `use Mix.Project`. Its `project/0` delegates to the user module then injects two overrides: append `{:mutalisk, path: System.fetch_env!("MUTALISK_PATH"), only: [:test], runtime: true}` to `:deps`; and (oracle role only) prepend the atom `:mut_oracle` to `:compilers`.
   - `application/0` delegates to the user module unchanged. **The overlay never replaces the user's `:mod` callback.** Mutalisk's runtime boot runs because `:mutalisk` is a dep, so OTP starts the `:mutalisk` application before the user app.
3. **Bootstrap modules** (loaded into the child BEAM via the path-dep, NOT referenced from the overlay file):
   - `Mix.Tasks.Compile.MutOracle` — a `Mix.Task.Compiler` shipped in mutalisk. The atom `:mut_oracle` in `:compilers` resolves to this module via Mix's standard `Mix.Tasks.Compile.<Camelize>` convention. Its `run/1` calls `Code.put_compiler_option(:tracers, [Mut.Trace | existing_tracers])`, starts `Mut.Trace.Writer`, and registers `System.at_exit/1` to flush + write the count sentinel before BEAM shutdown. Returns `{:noop, []}`. `manifests/0` returns `[]`. `clean/0` is a no-op.
   - `Mut.Application` — mutalisk's own OTP application callback module. Declared in mutalisk's own `mix.exs` as `mod: {Mut.Application, []}`. `start/2` reads `MUT_ACTIVE` from the environment, calls `Mut.Runtime.set_active/1`, then starts a real (childless) `Supervisor.start_link/2` and returns `{:ok, supervisor_pid}`. **Returning `{:ok, self()}` is forbidden** — the Application controller would monitor the calling process, not a supervisor.
4. **Worker bootstrap.** Workers run via `mix test --no-compile ...` with `MUT_ACTIVE=<id>` in the environment. Because mutalisk is a dep of the working copy, OTP starts `:mutalisk` before the user app, so `Mut.Application.start/2` fires and `:persistent_term` is set before any user code or test runs. **No `MIX_INIT`. No `--eval` injections. No replacement of the user's `:mod` callback.**
5. **Bootstrap load order.** The `:mut_oracle` compiler atom resolves to a module that lives inside the mutalisk dep. That module is loadable only after deps are compiled. Therefore every host-side child invocation runs deps.compile before compile:
   ```
   mix do deps.get + deps.compile --include-children mutalisk
   mix compile --force
   ```
   `deps.compile` is targeted by name (`mix deps.compile mutalisk`) when only mutalisk needs building.
6. **Tracer event handoff.** `Mut.Trace.Writer` is a GenServer started by `Mix.Tasks.Compile.MutOracle.run/1` before `:elixir` runs. All tracer callbacks send events to the writer; the writer batches and writes JSONL to `_build/mut_oracle/.mut_oracle.jsonl`. The final `{"event":"end","count":N}` sentinel is written from a `System.at_exit/1` hook registered in the same `run/1`, so it fires when the child BEAM shuts down (after Mix returns). Direct file appends from concurrent tracer callbacks are forbidden — `Kernel.ParallelCompiler` runs tracer callbacks in many processes simultaneously and unsynchronized appends interleave or lose events.

This contract is implemented in M0 (stub modules) and fully wired in M2. See `docs/BOOTSTRAP.md` for the concrete overlay template and edge-case test plan.

### Build-Path Contract

There are exactly four roles for build directories. Every command that compiles or runs tests in a target project MUST set both `MIX_ENV` and `MIX_BUILD_PATH` per this table — never omit either.

| Role | `MIX_ENV` | `MIX_BUILD_PATH` (relative to working copy root) | `MIX_DEPS_PATH` (relative to working copy root) | Purpose |
|---|---|---|---|---|
| Oracle build | `test` | `_build/mut_oracle` | `_build/mut_oracle/deps` | Tracer-instrumented compile; produces oracle JSONL + baseline beams |
| Baseline test run | `test` | `_build/mut_oracle` | `_build/mut_oracle/deps` | Pre-mutation green-baseline check; reuses the oracle build |
| Coverage build | `test` | `_build/mut_coverage` | `_build/mut_coverage/deps` | Tracer-coverage compile + baseline test run; produces line/function coverage oracle. |
| Schema build | `test` | `_build/mut_schema` | `_build/mut_schema/deps` | Compiles schema-instrumented sources; produces beams used by all workers |
| Worker test run (schema) | `test` | `_build/mut_schema` | `_build/mut_schema/deps` | `mix test --no-compile` only; `MUT_ACTIVE` env var selects mutant |
| Fallback recompile | `test` | `_build/mut_schema` (per-sandbox copy) | `_build/mut_schema/deps` (per-sandbox copy) | Targeted recompile inside sandbox before its `mix test --no-compile` |
| Worker test run (fallback) | `test` | `_build/mut_schema` (per-sandbox copy) | `_build/mut_schema/deps` (per-sandbox copy) | `mix test --no-compile`; mutant pre-baked into source + beams |

Notes:

- `MIX_BUILD_PATH` is always relative to the working-copy/sandbox root, never to the user's project.
- `MIX_DEPS_PATH` is always under the role build path so dependency fetching never writes through a working-copy `deps/` symlink into the user's project.
- `MIX_ENV` is always `test` in v1. The reasoning the SPEC gives for not introducing a separate env is honored.
- Worker `mix test` invocations always pass `--no-compile --no-deps-check --no-archives-check --max-failures 1` per SPEC §Phase 3.
- Fallback recompile must restore not only `.beam` files but also Mix manifest files (`compile.elixir`, `compile.elixir_scm`, etc.) from the sandbox baseline snapshot taken at sandbox checkout, otherwise the next `mix test --no-compile` may detect staleness and trigger an uncontrolled compile.

This contract is implemented incrementally — M2 (oracle row), M7 (schema row), M8 (worker schema rows), M10 (fallback rows).

## The verification harness (`bin/verify`)

A single shell entry point that the implementing agent runs to prove a milestone is done. The harness is layered; each layer is added at the milestone listed in `[layer M#]`.

| Layer | Scope | Added at |
|---|---|---|
| `lint` | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` | M0 |
| `unit` | `mix test` with `:integration` and `:e2e` ExUnit tags excluded by `test_helper.exs` | M0 |
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
- `mix.exs`: deps `:credo`, `:dialyxir`, `:jason`, `:ex_doc` (dev-only). Aliases for `lint`, `harness`. Elixir requirement matches SPEC (`>= 1.17`); update from `~> 1.20-rc`. **`def application` declares `mod: {Mut.Application, []}`** from M0 so dep-ordered boot works the moment any working copy depends on mutalisk.
- `.formatter.exs`, `.credo.exs` (strict, project-local opts).
- `bin/verify` shell script and `scripts/fixture_check.sh` already drafted in this repo (see `bin/verify`, `scripts/fixture_check.sh`); M0 task is to land the modules and fixture so `bin/verify` (lint + unit) goes green.
- `test/test_helper.exs`: `ExUnit.start(exclude: [:integration, :e2e])`.
- Bootstrap stubs (per `docs/BOOTSTRAP.md`, compile-clean):
  - `lib/mut/runtime.ex` — working: `active_key/0`, `set_active/1`, `get_active/0`, `clear/0`.
  - `lib/mut/application.ex` — working stub: reads `MUT_ACTIVE`, calls `set_active/1`, returns `{:ok, supervisor_pid}` from `Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Sup)`.
  - `lib/mut/bootstrap.ex` — working: `role/0` returning `:oracle | :schema | :worker | :fallback | nil`.
  - `lib/mut/bootstrap/overlay.ex` — skeleton with full API surface (`materialize/2`, `render/1`, `assert_not_umbrella!/1`); raises `RuntimeError, "not yet implemented (M2)"`.
  - `lib/mut/work_copy.ex` — skeleton; raises (M2).
  - `lib/mix/tasks/compile/mut_oracle.ex` — skeleton implementing `Mix.Task.Compiler` callbacks; `run/1` raises (M2). Module name is `Mix.Tasks.Compile.MutOracle` so the `:mut_oracle` atom resolves correctly via Mix's `Mix.Tasks.Compile.<Camelize>` convention.
  - `lib/mix/tasks/mut/recompile.ex` — skeleton (`use Mix.Task`); raises (M10).
  - `lib/mut/trace.ex`, `lib/mut/trace/writer.ex`, `lib/mut/oracle.ex` — compile-clean placeholders.
  - `lib/mutalisk.ex` — re-exports.
- Fixture skeleton: `test/fixtures/demo_app/{mix.exs,lib,test}` with empty modules and a single passing test per file. **Without the fixture, `bin/verify unit` is red** — landing the fixture is part of M0.
- `README.md`: minimal; pointer to SPEC, PLAN, and `docs/BOOTSTRAP.md`.

**Verification gate:** `bin/verify` runs `lint` + `unit` and exits 0. Fixture compiles and its (placeholder) tests pass.

**Out of scope:** Any logic, tracer events, mutators, working-copy materialization.

---

## M1 — Foundational types and `Mut.Runtime`

**Goal:** All structs and the persistent-term runtime helper are defined, with thorough specs and tests.

**Inputs:** SPEC §Mutant Model, §Runtime Selector, §Mutator Behaviour, §Fallback Patch Representation.

**Deliverables:**
- `Mut.Runtime`: `active_key/0`, `set_active/1`, `get_active/0`, `clear/0`. Thin `:persistent_term` wrappers.
- `Mut.Application`: an Application-callback module. `start/2` reads `MUT_ACTIVE` (default 0), calls `Mut.Runtime.set_active/1`, then `Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Sup)` and returns `{:ok, supervisor_pid}`. Tested by setting env var and observing `Mut.Runtime.get_active/0`. **Never returns `{:ok, self()}`** — that would attach OTP monitoring to the calling process. Mutalisk's own `mix.exs` declares `mod: {Mut.Application, []}` from M0 so dep-ordered boot works correctly the moment any working copy depends on mutalisk.
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
- `Mut.WorkCopy.install_overlay/2`: writes the overlay per `docs/BOOTSTRAP.md` template. Renames `mix.exs` → `mix_user.exs`. Asserts not-umbrella and refuses if the user already depends on a different mutalisk source.
- `Mix.Tasks.Compile.MutOracle`: implements `Mix.Task.Compiler`. Resolved by Mix from the `:mut_oracle` atom in the overlay's `:compilers` list. `run/1`:
  1. `Code.put_compiler_option(:tracers, [Mut.Trace | Code.get_compiler_option(:tracers) || []])`.
  2. `{:ok, _} = Mut.Trace.Writer.start_link(jsonl_path: Path.join(Mix.Project.build_path(), ".mut_oracle.jsonl"))`.
  3. Registers `System.at_exit(fn _ -> Mut.Trace.Writer.close_with_count() end)` so the sentinel is written when the child BEAM shuts down (after `:elixir` has finished and Mix has returned).
  4. Returns `{:noop, []}`. `manifests/0` returns `[]`. `clean/0` is a no-op.
- `Mut.Application`: mutalisk's own OTP `Application` callback module. Declared in mutalisk's `mix.exs` as `mod: {Mut.Application, []}`. `start/2` reads `MUT_ACTIVE`, calls `Mut.Runtime.set_active/1`, then `Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Sup)` and returns `{:ok, supervisor_pid}`.
- `Mut.Trace`: implements all SPEC tracer events. Filters per SPEC §Generated-Code Filtering. Sends each accepted event as a `%DispatchSite{}` to `Mut.Trace.Writer` via `cast`.
- `Mut.Trace.Writer`: GenServer. Buffered async writes to JSONL; `flush/0` and `close_with_count/0` callable from the at_exit hook. Concurrent casts from parallel-compile worker processes are serialized by the GenServer mailbox. Writes a final `{"event":"end","count":N}` sentinel; readers fail if sentinel missing.
- `Mut.Oracle`: Agent/ETS store with `start_link/1`, `put_site/1`, `lookup_by_key/1`, `lookup_by_file_line/2`, `dump_json/1`, `load_jsonl/1` (validates sentinel + count). Stable serialization order.
- `Mut.OracleBuild.run/2`: drives the working copy → overlay → child Mix invocations. Two commands, sequential:
  ```
  # Step 1: ensure mutalisk dep is built so :mut_oracle compiler module is loadable
  System.cmd("mix", ["do", "deps.get", "+", "deps.compile", "--include-children", "mutalisk"],
    cd: working_copy,
    env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_oracle"}, {"MUTALISK_ROLE", "oracle"}, {"MUTALISK_PATH", host_mutalisk_root}])

  # Step 2: project compile with tracer
  System.cmd("mix", ["compile", "--force"],
    cd: working_copy,
    env: same_env)
  ```
  Reads back the JSONL into `Mut.Oracle`. Fails if sentinel/count don't match received-events count, OR if the JSONL file is missing entirely (indicating the bootstrap compiler did not run).
- Golden test: oracle JSON dump of the fixture; regenerate-on-demand with `MUT_REGOLD=1`.
- **Negative DSL test (calibrated, not over-claimed):** the fixture's `dsl_def.ex` defines a macro using plain `quote do def f(x), do: x + 1 end` (no `location: :keep`). The fixture's `dsl_user.ex` calls that macro. The test asserts: the operator `+` inside the expanded `def` does NOT appear in the oracle, because Elixir's macro expansion sets `generated: true` on the `quote`-emitted nodes' meta and our filter drops them on `Keyword.get(meta, :generated, false) == true`. **The test is calibrated against observed Elixir behavior, not asserted from theory.** If a future Elixir release changes the meta, the test fails and the filter must be revisited. A second test variant using `quote location: :keep` is marked `@tag :known_limitation` and asserts the current behavior (filtered or not) so future changes are visible. The plan does not promise that `:keep` macros are filtered in v1.

**Verification gate:** `bin/verify` enables `golden_oracle`. Oracle JSON for the fixture matches committed golden file. Negative DSL test passes for the default-quote case.

**Subagent brief:** The bootstrap compiler must run before `:elixir`. Validate by adding a temporary `IO.puts` in `Mix.Tasks.Compile.MutOracle.run/1` and confirming it fires before any module of the user app compiles. The two-step `deps.compile mutalisk` then `compile --force` is mandatory — without step 1 the `:mut_oracle` atom resolves at compile-list-evaluation time but the underlying module is missing from the code path.

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
- `Mut.SchemaBuild.build/2`: `(plan, opts)` → produces an instrumented build at `<working_copy>/_build/mut_schema`. With `MIX_BUILD_PATH=_build/mut_schema`, Mix writes app artifacts under `_build/mut_schema/lib/<app>/...` (no extra `test/` path segment). Steps:
  1. Materialize a fresh working copy for the schema phase; do not reuse the oracle working copy because schema build overwrites `lib/`.
  2. Reinstall overlay in **schema role**. The overlay differs from oracle role only by NOT prepending `:mut_oracle` to `:compilers`. It still adds `mutalisk` as a `:path` dep. `application/0` is delegated unchanged to the user's module — **the overlay does not replace `:mod`**. `Mut.Application` runs because `:mutalisk` is a dep, OTP starts it before the user's app, and its `start/2` reads `MUT_ACTIVE` into `:persistent_term`.
  3. Write instrumented source files over the working-copy `lib/` (and `test/` is left untouched).
  4. Run, in sequence:
     ```
      System.cmd("mix", ["do", "deps.get", "+", "deps.compile", "--include-children", "mutalisk"], cd: working_copy, env: env)
     System.cmd("mix", ["compile", "--force"],       cd: working_copy, env: env)
     ```
     where `env = [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_schema"}, {"MUTALISK_ROLE", "schema"}, {"MUTALISK_PATH", host_mutalisk_root}]`.
  5. Snapshot `_build/mut_schema/lib/<app>` (recursive list of files + content hashes) for sandbox reset later; dependency/path-dep artifacts such as `mutalisk`, `jason`, and host `priv/plts` are not part of the target-app snapshot.
- `Mut.CompileRollback.run/3`: parses Elixir compiler diagnostics, locates the surrounding instrumented `case` by line/col + `mut_ids` metadata, removes those mutants from the placer plan (transitions them to `:invalid` with diagnostic attached), re-renders the file, and recompiles. Honors `max_rollback_iterations: 3` and `max_invalid_mutants_per_file: max(10, ceil(file_mutants * 0.02))`.
- `Mut.Mutator.Test.AlwaysWrong` (test-only): emits non-compiling AST. Drives a rollback test asserting budgets are enforced and that good mutants survive.

**Verification gate:** Existing layers + `golden_instrument`. New rollback tests under `test/rollback_test.exs`.

**Out of scope:** Worker VMs, fallback engine, scheduling.

---

## M8 — Sandbox pool + worker (Port-driven `mix test`)

**Goal:** Run isolated `mix test` invocations inside per-worker sandbox copies of the schema build, switching the active mutant via `MUT_ACTIVE` env var (read by `Mut.Application` at app start).

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
  `Mut.Application` (mutalisk's own OTP application callback, registered in mutalisk's own `mix.exs` via `mod: {Mut.Application, []}`) starts before the user app because `:mutalisk` is a dep of the working copy. Its `start/2` reads `MUT_ACTIVE` and calls `Mut.Runtime.set_active/1` before any user code runs. **The overlay does not modify the user's `application/0` callback or `:mod` spec.**
- `Mut.Worker.Formatter`: a custom ExUnit formatter writing structured per-test results to stdout in JSONL form for the parent to parse.
- Result classification per SPEC: `:killed | :survived | :timeout | :error`. `:invalid` comes from rollback (M7), not workers.
- Single retry for `:error` per SPEC.
- Integration test (under `mix mut.test_schema`): for each known mutant in `arith.ex`, run worker and assert killed/survived as documented.

**Verification gate:** `bin/verify` enables `integration_schema`. Golden expectation: hand-curated set of ~10 known mutant outcomes against the fixture.

**Subagent brief:** Pre-implementation, manually validate `mix test --no-compile` skips compile after a successful schema build. Validate `MUT_ACTIVE` is observed by `Mut.Application.start/2` by setting `MUT_ACTIVE=42`, running the worker against a one-line test that calls `IO.inspect(Mut.Runtime.get_active())`, and confirming `42` appears.

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
- `Mut.MixManifest.read/1`: parses `_build/mut_schema/lib/<app>/.mix/compile.elixir`. Tolerant of Elixir 1.17+ format variants. Exposes module-to-source and source dependency graph (compile, export, struct, runtime). Has an explicit `version_assertion/1` that fails loudly on unknown shape.
- `Mut.Recompile.dependents/2`: walks `[:compile, :struct, :export]` edges (transitive `:compile`). Ignores `:runtime`.
- `Mix.Tasks.Mut.Recompile`: a custom Mix task shipped in mutalisk. Accepts a list of source files plus `--app` and an optional `--ebin <dir>`; resolves the target ebin (defaults to `<MIX_BUILD_PATH>/lib/<app>/ebin`); calls `Kernel.ParallelCompiler.compile_to_path(files, ebin)`. Runs **inside the sandbox's Mix env** so deps are loaded. This is the SPEC-mandated targeted compile — full `mix compile` is forbidden by SPEC §Fallback Engine.
- `Mut.Recompile.recompile/3`: host-side driver. `(sandbox, mutated_source_files, dependents)` →
  ```
  System.cmd("mix", ["mut.recompile", "--app", app] ++ mutated_source_files ++ dependent_source_files,
    cd: sandbox,
    env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", "_build/mut_schema"}, {"MUTALISK_ROLE", "fallback"}, {"MUTALISK_PATH", host_mutalisk_root}])
  ```
  Both lists are sandbox-relative paths such as `lib/foo.ex`. The task itself runs in the sandbox BEAM (via the existing `:mutalisk` path-dep). The host never invokes `Kernel.ParallelCompiler` directly.
  - Fallback writes the patch to `lib/...` in the sandbox before recompile, so `mix mut.recompile` reads the patched source.
  - `Mut.Recompile.dependents/2` (manifest walk) is the source of truth for which files to pass; we do NOT delegate to Mix's incremental compile because that would also rebuild unrelated changed files and is forbidden by SPEC.
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
| `MUT_ACTIVE` not seen by `Mut.Application.start/2` | M8 | Validated in M8 subagent brief by IO.inspect; mutalisk's own `mix.exs` declares `mod: {Mut.Application, []}` so OTP boot order does the work without overlay manipulation |
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

---

# v1.5 Milestones

v1.5's stated goal is making v1 practical on medium libraries by reducing per-mutant test work. v1.5 does NOT improve kill rate (kill rate is a function of the user's test suite); it reduces wall-clock by narrowing the per-mutant test set and exposes phase timings.

The acceptance signal is Decimal: either it completes within a documented budget OR coverage selection demonstrably reduces per-mutant test fanout by ≥10× and v1.5's BENCHMARKS identifies the next blocking bottleneck.

v1.5 is two milestones (M15 and M16). Each ships as an independently reviewable increment. M15 alone is useful (phase timing answers questions today); M16 lights up the actual perf win.

## M15 — Coverage infrastructure + phase timing

**Goal:** Add the coverage data path and phase-timing instrumentation. M15 ships ALL the measurement plumbing v1.5 needs without yet changing test selection. After M15, runs are no faster but are far more observable.

**Inputs:** `ELIXIR_MUTATION_TESTING_HLD_V1_5_V2.md` v1.5 sections; v1's `Mut.Metrics`, `Mut.WorkCopy`, `Mut.OracleBuild`, `Mut.SchemaBuild`, `Mut.Worker`, `Mut.Reporter.Terminal`, `Mut.Reporter.StrykerJson`.

**Deliverables:**

- **Build-Path Contract update.** Add a new role row:
  - `Coverage build` | `MIX_ENV=test` | `MIX_BUILD_PATH=_build/mut_coverage` | `MIX_DEPS_PATH=_build/mut_coverage/deps` | `MUTALISK_ROLE=coverage` | "Baseline test run under `:cover`; produces line/function coverage oracle."
  Update PLAN's Build-Path Contract table.

- **`Mut.Coverage.Runner`**: drives a baseline test run under `:cover` in an isolated working copy. Per-test-file/module attribution (NOT per-case). `async: false` set in the coverage run only. Captures `:cover.analyse(:coverage, :line)` and `:cover.analyse(:coverage, :function)` output.

  Signature: `run(work_copy_root, opts) :: {:ok, %Mut.CoverageOracle{}} | {:error, term}`. Implementation shells `mix test --no-deps-check --no-archives-check` with the `MIX_BUILD_PATH` override and a `MUTALISK_COVERAGE=1` env var that triggers the coverage-mode test_helper changes.

- **`Mut.Coverage.Parser`**: normalizes `:cover` output into:
  ```elixir
  %Mut.CoverageOracle{
    by_line: %{{file, line} => MapSet.t(test_id)},
    by_function: %{{module, fun, arity} => MapSet.t(test_id)},
    test_runtime_ms: %{test_id => non_neg_integer()},
    fallback_static_tests: %{module => [test_id]}
  }
  ```
  `test_id` is a `{:file | :module, path_or_module}` tagged tuple per HLD §Data Model. Per-case (`:case`) reserved for v2.

- **`Mut.TestRuntime`**: records per-test-file/module baseline runtime in milliseconds during the coverage run. Sourced from the JSONL output of `Mut.Worker.Formatter` (already emits per-test-finished durations in M8).

- **Phase timing in `Mut.Metrics`.** Extend `%Mut.Metrics.Snapshot{}` with:
  ```elixir
  %{phase_timings: %{
      oracle_build_ms: ms,
      baseline_tests_ms: ms,
      plan_generation_ms: ms,
      coverage_collection_ms: ms,  # 0 in static mode
      schema_build_ms: ms,
      schema_workers_ms: ms,
      fallback_workers_ms: ms,
      report_writing_ms: ms,
      total_ms: ms
    }}
  ```
  Use `:os.system_time(:millisecond)` (monotonic) for measurement.

- **Reporter updates.**
  - `Mut.Reporter.Terminal.render_summary/1` displays a phase-timings block at the bottom: `oracle 1.2s | baseline 4.8s | plan 0.1s | coverage 0.0s | schema 6.4s | schema workers 18.0s | fallback workers 41.0s | report 0.1s | total 71.7s`.
  - `Mut.Reporter.StrykerJson.render/4` includes `phase_timings` in the `mutalisk` extension key.
  - Both updates are golden-tested (synthetic snapshot with known timings).

- **Mix task wiring.** `Mix.Tasks.Mut` records phase entries via the new `Mut.Metrics.start_phase/2 + end_phase/2` (or equivalent) helpers around each pipeline phase. M15 does NOT yet collect coverage in `mix mut` (coverage is opt-in starting in M16); the `coverage_collection_ms` field stays at zero.

- **`Mut.Coverage.Runner` standalone test.** A unit test runs the coverage runner against demo_app and asserts the oracle has by_line entries for known fixture lines (e.g., `lib/arith.ex:5` is hit by `arith_test.exs`).

**Verification gate:** `bin/verify` exits 0 with all 8 v1 layers green. No new layer added; M15 reuses `unit` for coverage-runner tests, `golden_oracle` for the synthetic phase-timing JSON golden, and the existing integration layers (which exercise the phase-timing path).

**Out of scope for M15:**

- Coverage-aware test selection (M16).
- The `--selection` CLI flag (M16).
- Decimal smoke run (M16).
- Persistent caching of the coverage oracle.
- Per-test-case attribution.

**Subagent brief:**

The risk concentration is `:cover` interaction with the schema build. M15's coverage runner runs against the ORIGINAL user source (not the schema-instrumented source) — `:cover` and the schema's `case` injection do not coexist cleanly. Coverage run uses its own `_build/mut_coverage` build path; schema run uses `_build/mut_schema`. Two builds, two cover-or-not states, no overlap.

Pre-implementation: in a tmp working copy, manually run `MIX_ENV=test MIX_BUILD_PATH=_build/test_cover mix test --cover` to confirm `:cover` works against demo_app's lib/. If it fails or interacts badly with the path-dep mutalisk, resolve before writing the runner.

Phase timing is the cheap deliverable. Land that first; it doesn't depend on coverage at all.

**Recommended commit pacing:** 3 commits.

1. Phase timings in `Mut.Metrics` + reporter updates + golden updates.
2. Build-Path Contract update + `Mut.Coverage.Runner` + `Mut.Coverage.Parser` + `%Mut.CoverageOracle{}`.
3. Standalone coverage-runner integration test against demo_app.

---

## M16 — Coverage-aware selector + smoke run

**Goal:** Wire coverage-aware test selection into `mix mut`, ship the `--selection` CLI flag, run the v1.5 smoke benchmark on plug_crypto + Decimal, update `BENCHMARKS.md`. M16 is where the perf win lights up.

**Inputs:** `ELIXIR_MUTATION_TESTING_HLD_V1_5_V2.md` v1.5 sections; M15's `Mut.CoverageOracle` and phase timings; v1's `Mut.TestSelection.Static`, `Mut.Worker`, `Mix.Tasks.Mut`.

**Deliverables:**

- **`Mut.TestSelection.Coverage`**: extends the v1 facade. `for_plan(plan, oracle, opts)` returns `%{stable_id => [test_id]}`. Selection priority chain per HLD §Core Idea:
  1. Exact line: `oracle.by_line[{file, line}]` returns ≥ 1 test.
  2. Enclosing function: `oracle.by_function[{module, fun, arity}]` returns ≥ 1 test.
  3. Static dependency selection (existing M9 path).
  4. All tests as final safety fallback.

  Each mutant gets a tagged result: `{:exact_line | :enclosing_function | :static_fallback | :all_tests, [test_id]}`. The tag drives the `coverage_match_distribution` metric.

- **Test ordering** within a selected set:
  1. In-run last-killer for the same module if present (see `Mut.LastKiller` below).
  2. Convention match (e.g., `FooTest` for `Foo`).
  3. Shortest baseline runtime first (from `Mut.TestRuntime`).
  4. Stable path/name ordering for determinism.

- **`Mut.LastKiller`**: a tiny in-run, in-memory cache. `record_kill(module, test_id)`; `lookup(module) :: test_id | nil`. Process-local (Agent or `:persistent_term` namespaced to the current run). NOT persisted between runs.

- **`Mix.Tasks.Mut` CLI extension**:
  - New `--selection MODE` flag accepting `static | coverage | coverage_with_static_fallback`.
  - Default: `static`. (Coverage modes are opt-in for the first v1.5 release. A follow-up may flip the default.)
  - Mode is reported in terminal output ("Selection mode: coverage_with_static_fallback") and in the JSON's `mutalisk` extension key.

- **Mode-specific fallback policy** (HLD §Selection Modes):
  - `static`: skip M15's coverage runner entirely; `coverage_collection_ms = 0`.
  - `coverage_with_static_fallback`: run coverage; if `coverage_collection_ms > 2 * baseline_tests_ms`, log a warning, set `selection_mode: :downgraded_to_static` in metrics, fall back for the remainder of the run.
  - `coverage`: run coverage; if collection is pathological (same threshold), FAIL with a clear error referencing the mode and timing. Does NOT silently downgrade.

- **Selection metrics** in `Mut.Metrics.Snapshot`:
  ```elixir
  %{selection: %{
      mode: :static | :coverage | :coverage_with_static_fallback | :downgraded_to_static,
      coverage_match_distribution: %{
        exact_line: count, enclosing_function: count,
        static_fallback: count, all_tests: count
      },
      fallback_reason_distribution: %{atom => count},
      selected_tests_avg: float,
      selected_tests_median: pos_integer,
      coverage_collection_wall_ms: ms
    }}
  ```

- **Reporter updates**:
  - Terminal: add a "Selection:" section showing the mode + match distribution + average fanout.
  - Stryker JSON: add `selection` block to the `mutalisk` extension key.
  - Synthetic golden updated to cover the new fields.

- **Smoke run**: extend `bench/run.sh` to support `--selection coverage` runs. Re-run plug_crypto AND retry Decimal under `coverage_with_static_fallback`. Update `BENCHMARKS.md` with:
  - Side-by-side comparison of v1 vs v1.5 numbers per target (wall-clock, average fanout, mode).
  - Decimal completion outcome (success with timing, OR documented bottleneck after coverage).
  - Phase-timing breakdown for both targets.

- **Non-regression on demo_app**: the existing e2e test runs in `static` mode by default (unchanged). Add a parallel e2e run in `coverage_with_static_fallback` mode asserting same kill/survive outcomes (33 mutants, ~21-23 killed) but reduced fanout per the new selection metrics.

**Verification gate:** `bin/verify` exits 0 with all 8 v1 layers green PLUS the new e2e_mut variant for coverage mode. The smoke benchmark on plug_crypto produces zero `:error`-status mutants. Decimal acceptance per the criterion (completion within budget OR ≥10× fanout reduction with documented next bottleneck).

**Out of scope for M16:**

- Per-test-case coverage attribution.
- Persistent cross-run history.
- Parallel worker execution.
- Source probes (Option C from HLD).
- Coverage-driven kill prediction or any heuristic beyond the documented priority chain.
- Modifying the schema or fallback engines.

**Subagent brief:**

This milestone has two distinct risk surfaces: (a) selection correctness — wrong narrowing produces silent false-survivor or false-kill drift — and (b) Decimal acceptance — there's no guarantee coverage alone moves Decimal under the budget.

For (a): the demo_app non-regression e2e (same outcomes in coverage mode as static mode) is the primary correctness test. Run it BEFORE the smoke benchmark; if outcomes drift, the selector has a bug. The selection priority chain's correctness is testable in unit tests with constructed oracles.

For (b): the smoke is informational, not gating. If Decimal doesn't fit under coverage_with_static_fallback within 30 minutes, document the actual time + the next bottleneck (e.g., "schema build dominates because Decimal has 30 lib files; schema build takes 18 minutes alone"). That's an honest report; v1.5 still ships if (a) is correct and the metrics are valuable. Failure on (b) escalates to the orchestrator (you), who decides whether v1.5 widens to include a M17 (parallel workers) or ships as-is and v1.6 picks up.

The `coverage` (strict) mode's failure path is important: when collection is pathological, the error message must say "coverage collection took Xs vs baseline Ys; 2× threshold exceeded; rerun with --selection coverage_with_static_fallback or static." Users in strict mode chose to fail loudly; respect that.

**Recommended commit pacing:** 4 commits.

1. `Mut.TestSelection.Coverage` + selector priority chain + unit tests with constructed oracles.
2. `Mut.LastKiller` + test-ordering integration in the selector.
3. `--selection` CLI flag + mode wiring through `Mix.Tasks.Mut` + selection metrics + reporter updates + golden updates.
4. Bench script extension + smoke runs + `BENCHMARKS.md` update.

---

# Out of scope for v1.5 (do not let it sneak in)

- Per-test-case coverage attribution.
- Source probes (mutation-site coverage instrumentation).
- Persistent incremental history (cross-run reuse).
- Parallel worker execution.
- Coverage caching between runs.
- Any new mutator (literal, pattern, variable, function-call deletion, return-value replacement).
- Env walker (M5's syntactic walker stays unchanged).
- Wrapper guard schemata.
- Coverage data entering stable_id input.

If coverage selection on Decimal proves insufficient, parallel workers are reconsidered as a v1.6 standalone milestone — NOT folded into v1.5 mid-milestone.

---

# v1.6 Milestones

v1.6 is a performance-hardening release. Its theme: parallel workers as the reliable default path. The work is empirical (validate, measure, harden) plus light documentation. v1.6 is NOT new features.

The PROMPT_16 mission landed:
- Parallel-worker prototype behind `--concurrency N` (default 1).
- Decimal at `--concurrency 4`: 33.5 min → 11.0 min (3.06× wall, byte-identical outcomes vs c=1 on plug_crypto).
- Fallback recompile bypasses Mix entirely (elixir-direct invocation), eliminating the lock-check failure mode that produced 75/75 invalid on Decimal.
- Persistent-BEAM spike measurements at `bench/spike/persistent_beam.exs` (cold 8.8ms, hot 80μs in-process).
- Design recommendation in `V16_PERFORMANCE.md`: parallel default first (v1.6), persistent BEAM second (v1.7).

v1.6 is two milestones: M17 hardens parallel execution to production quality; M18 lands the persistent-worker design contract for v1.7.

## M17 — Parallel hardening + default + fallback recompile tests

**Goal:** Make parallel execution correctness-preserving and durable across Decimal-class targets. Flip the default. Tighten the fallback recompile path that PROMPT_16 introduced. After M17, `mix mut` defaults to parallel, with sequential reachable via `--concurrency 1`, and Decimal-class projects complete comfortably under 30 minutes.

**Inputs:** `V16_PERFORMANCE.md`; `BENCHMARKS.md` post-PROMPT_16; `lib/mut/sandbox_queue.ex`; `lib/mut/last_killer.ex`; `lib/mut/recompile.ex` and the new elixir-direct fallback path; existing M9 test selection; existing `Mix.Tasks.Mut`.

**Deliverables:**

- **Concurrency validation matrix.** Run `bin/verify` at `--concurrency 1`, then run smoke benchmarks at `--concurrency 1/2/4/8` against demo_app, plug_crypto, and Decimal. Capture wall-clock + outcomes per target per concurrency level. Document the speedup curve in BENCHMARKS.md.
- **Correctness acceptance**: outcomes byte-identical at c=1 vs c=4 across all three targets. Same kill/survived/timeout/error/invalid counts. Same set of stable_ids in killed and survived buckets. Document any drift; fix any non-trivial drift.
- **Wall-clock acceptance**: Decimal `--concurrency 4` ≤ 15 minutes on the reference machine (current: 11 min — non-regression bar, not aspirational).
- **Fallback acceptance**: zero invalid fallback mutants from recompile infrastructure on Decimal at any concurrency level.
- **`Mut.LastKiller` audit.** Currently an Agent; verify it's race-safe under c=8 sustained record_kill/lookup churn. If contention is observed, switch to `:persistent_term` or ETS with concurrent access. Add focused tests stress-running the killer with N concurrent producer processes.
- **Sandbox correctness audit.** Inspect `Mut.Sandbox.checkout/checkin/reset` for shared mutable state, cross-worker build-path leakage, race conditions on directory creation/deletion, and `mix.lock` contention. Land focused tests for any issue found. The acceptance assertion is "two workers can checkout, run a mutant, checkin concurrently without observable interference."
- **Default concurrency policy.** Flip default from `1` to `min(System.schedulers_online(), 4)`. Cap at 4 for the first v1.6 release; users with more cores can override with `--concurrency 8` or higher. Cap exists because the speedup curve flattens past 4 on the reference machine; safer ship state.
- **Reports include concurrency metadata.** Terminal output and Stryker JSON's `mutalisk` extension key carry `configured_concurrency`, `effective_concurrency` (at most schedulers_online()), and `worker_count` (actual). Useful for users diagnosing parallelism issues.
- **Fallback recompile hardening.**
  - Doc comment in `Mut.Recompile` (or wherever the elixir-direct path lives) explaining why Mix is bypassed and what trade-off exists (no lock validation; runtime mismatches surface at test execution rather than recompile).
  - Targeted regression tests for the elixir-direct path: deps loaded correctly, all sandbox ebins on `-pa`, transitive dep modules accessible.
  - Improved error diagnostics: when fallback fails, distinguish (a) compile failure in the patched module, (b) missing dependency module, (c) test runtime failure unrelated to the patch. Each gets a distinct error message and `compile_error` field shape.
- **CHANGELOG/BENCHMARKS guidance.** Add a top-of-BENCHMARKS section noting the v1.6 default change. CHANGELOG entry: "v1.6 defaults to parallel workers (`--concurrency 4` by default). Use `--concurrency 1` for sequential execution."

**Verification gate:** `bin/verify` exits 0 with all 8 layers green at default concurrency (now parallel). All concurrency-validation acceptance criteria above met. Plug_crypto and Decimal smoke runs documented in BENCHMARKS.md at c=1/2/4/8.

**Out of scope for M17:**

- Persistent worker production code (M18 is design only; production is v1.7).
- New mutators (any kind).
- Coverage default flip (still opt-in in v1.6).
- Per-test-case coverage attribution.
- Oracle/schema build Mix bypass (only fallback recompile is bypassed; the rest stays Mix-driven).
- Changing mutation semantics.
- Changing stable_id input.

**Subagent brief:**

This milestone has three risk surfaces in priority order:

1. **Sandbox concurrency correctness.** The PROMPT_16 mission validated parallel at c=4 on plug_crypto and Decimal but didn't audit the sandbox internals for race hazards. M17's audit is the load-bearing assertion. The auditor should construct a synthetic stress test (N=8 workers running mutants against a fixture for 5 minutes) and verify zero spurious failures. If failures surface, root-cause and fix BEFORE moving to other deliverables.

2. **Fallback recompile correctness.** The elixir-direct path bypasses Mix's lock validation. On a sandbox with stale `mix.lock`, runtime errors surface during test execution instead of recompile. M17's diagnostics should distinguish these cleanly. Add a synthetic test that constructs a stale-lock sandbox and observes the failure path.

3. **Default concurrency choice.** Flipping the default is user-visible. If the speedup curve shows c=2 is nearly as good as c=4 on the reference machine, default to c=2 instead — fewer workers means lower memory ceiling. Empirics decide; don't pre-commit.

**Recommended commit pacing:** 5-6 commits.

1. Concurrency validation runs + BENCHMARKS update with c=1/2/4/8 numbers per target.
2. `Mut.LastKiller` audit + hardening + concurrent stress test.
3. Sandbox checkout/checkin/reset audit + any fixes + concurrent stress test.
4. Default concurrency flip + reports include metadata + CHANGELOG.
5. Fallback recompile doc + regression tests + improved diagnostics.
6. (If needed) Final pass: re-run validation at the new default, confirm BENCHMARKS still accurate.

---

## M18 — v1.7 persistent worker design

**Goal:** Convert the PROMPT_16 spike measurements into a contract for `Mut.Worker.Persistent`. Identify ExUnit lifecycle hazards, define crash recovery, sketch unsupported test patterns. Single design document, no production code.

**Inputs:** `bench/spike/persistent_beam.exs`; `V16_PERFORMANCE.md`; ExUnit internals (process lifecycle, async tests, formatter callbacks, setup/teardown).

**Deliverables:**

- **`V17_PERSISTENT_WORKER.md`** (new design doc), covering:
  - **Contract**: `Mut.Worker.Persistent.start_link/1`, `run_mutant/3`, `stop/1`. Inputs, outputs, side effects.
  - **Lifecycle**: when is the persistent BEAM started, how does it stay alive between mutants, when does it terminate.
  - **Isolation model**: what state is reset between mutants (persistent_term flip), what state isn't (compiled modules, ExUnit configuration, loaded test files).
  - **ExUnit state reset strategy**: enumerate the leak vectors (Application env mutations, ETS table writes, `Process.put`-style state, mocked-module residue, async test residue) and pin a reset approach for each. Cite specific ExUnit internals where the reset hooks live.
  - **Unsupported test patterns**: tests that genuinely cannot run safely in a persistent worker (e.g., tests that mutate global ETS without cleanup, tests that depend on per-process compilation state). Document; recommend `--worker-type mix` fallback for these.
  - **Crash recovery**: when the persistent BEAM dies mid-mutant, how does the host detect (heartbeat? exit signal?), restart (new BEAM, same sandbox), and resume (skip the killed mutant or retry it)?
  - **Concurrency interaction**: persistent workers + parallel pool = N concurrent persistent BEAMs. Verify the multiplier is real (each BEAM at ~1ms/mutant × 4 BEAMs = 250 mutants/second sustained).
  - **v1.7 acceptance criteria sketch**: per-mutant median <50ms on demo_app; Decimal ≤ 2 minutes at c=4 with persistent workers; demo_app and plug_crypto outcomes byte-identical to v1.6.
  - **Implementation cost estimate**: PROMPT_16 estimated ~590 LOC. M18 refines.
  - **Risks and unknowns**: what could derail v1.7. Not a defense; an honest map.
- Update `ELIXIR_MUTATION_TESTING_HLD_V1_5_V2.md`'s v2 section to reference V17_PERSISTENT_WORKER.md and adjust the milestone naming if appropriate (v1.7 vs v2).

**Verification gate:** `bin/verify` exits 0 (no code changes expected). M18 is a docs-only commit.

**Out of scope for M18:**

- Production `Mut.Worker.Persistent` code.
- Modifying the existing M8 worker.
- Modifying `Mix.Tasks.Mut`.
- Modifying spike scripts (they're measurement tools; leave them).

**Recommended commit pacing:** 1 commit. Title: "Add v1.7 persistent worker design (V17_PERSISTENT_WORKER.md)".

---

# Out of scope for v1.6 (do not let it sneak in)

- Persistent worker production code (v1.7).
- New mutators (any kind).
- Coverage selection default flip (stays opt-in until v1.7+).
- Per-test-case coverage attribution.
- Oracle/schema build Mix bypass.
- Changing mutation semantics or stable_id input.
- New CLI flags beyond what's needed for concurrency reporting.
- Persistent incremental history.

If M17 surfaces a sandbox concurrency bug requiring rework >100 lines, escalate. Don't silently expand M17 into a refactor.

---

# v1.7 Milestones

v1.7 ships persistent BEAM workers as an **opt-in** worker type. The goal is correctness-preserving per-mutant cost reduction (~50× per the V17 spike). Default stays `mix` for the first v1.7 release; flip to `persistent` after a follow-up release validates on real projects (same conservative discipline as v1.5's static-first / v1.6's concurrency-cap-4-first).

**Important acceptance correction**: the original V17 sketch targeted "Decimal ≤2 min at c=4." That target is too aggressive as a hard gate. Decimal currently has 21 mutants that hit the 60s per-mutant timeout cap; even with infinitely-fast non-timeout mutants, the lower bound at c=4 is `21 × 60s / 4 ≈ 315s` (5.25 min). Treat ≤2 min as aspirational; gate on **material improvement over M17 c=4 (11 min)** instead. Reducing timeout duration or changing timeout classification is explicitly out of scope.

v1.7 is a **single milestone** (M19) with 8 ordered commit-steps. The intermediate "schema-only persistent" state is not independently shippable to users — they need fallback support to test real projects. The 8 steps provide review structure within the single milestone; the public CLI flag (`--worker-type persistent`) is not exposed until step 7 (after schema + fallback both work).

## M19 — Persistent worker (opt-in)

**Current status after review:** landed and accepted for v1.7.0. Persistent ships as opt-in supported (`--worker-type persistent`); the `MUTALISK_PERSISTENT_EXPERIMENTAL=1` env gate was removed in Mission F3.

Closed since the original status note:
- `e2e_persistent` is enabled (9th `bin/verify` layer; runs `mix mut.e2e --worker-type persistent` and asserts demo_app byte-identity for default/coverage/attribute fixtures).
- First-mutant reset-baseline bug fixed (`8af63d1`); regression test added.
- `--no-halt` removed from the worker BEAM bootstrap so spawned BEAMs no longer survive port closure (`8af63d1`).
- F1 filter-miss fix: `apply_file_filter/2` no longer silently runs every loaded test when the requested file list misses the index. It returns `{:error, {:filter_miss, files}}` and the host reroutes the mutant via the mix-spawn worker (`bf88bec`). Index keys + lookups are now both `Path.expand`'d so absolute-vs-relative path mismatches resolve.
- F2 project-app-startup fix (`bfd1ab5`): the persistent runner now scans `_build/mut_schema/lib/*/ebin/*.app` and starts every project app before capturing the leak baseline. Without this, `Application.start/2` callbacks never fired so resources they create (named ETS tables, registered processes) were missing. plug_crypto's `Plug.Crypto.Application` creates the named `Plug.Crypto.Keys` ETS table this way; tests calling `sign`/`encrypt` failed with `:badarg`. plug_crypto persistent at c=4 is now byte-identical to mix (38 Killed / 25 Survived / 1 Timeout).
- Decimal validated under V17 acceptance: 11 Timeout → Killed flips on the existing timeout-class mutants (allowed), 1 RuntimeError → Killed, 0 unexpected Survived → Killed regressions. Wall-clock 12.4 min vs 11.0 min mix.

**Goal:** Production-quality opt-in persistent workers. After M19, users can run `mix mut --worker-type persistent` and get ≥10× per-mutant cost reduction on supported projects, with `mix` remaining the default and validated escape hatch.

**Minimum Elixir version**: v1.7 raises the project's required Elixir from `>= 1.17.0` to `>= 1.18.0`. Update mutalisk's `mix.exs` accordingly. Rationale: V17's reset strategy depends on ExUnit internals (`ExUnit.OnExitHandler`, `ExUnit.Server.modules_loaded/1`, `ExUnit.configure(only_test_ids: ...)`) that are stable from 1.18 onward. Pre-1.18 users stay on mutalisk 1.6.x. CHANGELOG records the bump as a breaking change.

**Inputs:** `V17_PERSISTENT_WORKER.md` (M18's design contract); `bench/spike/persistent_beam.exs` (PROMPT_16's measurements); `lib/mut/worker.ex` (existing mix-spawn worker); M17's `--concurrency` plumbing; existing `Mut.Sandbox` and `Mut.LastKiller`.

### Step-by-step deliverables (7 commits)

**Step 1 — `Mut.Worker.Persistent` schema-only skeleton.** Host-side GenServer + Port-driven persistent BEAM. BEAM loads sandbox code, `test_helper.exs`, and selected test files once. Mutant runs flip `:persistent_term` and re-run ExUnit. NO fallback support yet (fallback mutants route to existing mix-spawn worker). NO crash recovery yet.

Acceptance for step 1: demo_app schema mutants produce byte-identical outcomes vs mix worker. Per-mutant median <50ms on demo_app schema. Private `--worker-type` flag exists but is undocumented. Bumps `mix.exs` Elixir requirement to `>= 1.18.0` in this commit.

**Step 2 — Reset hooks + leak fixture.** Implement V17's per-vector reset strategy (Application env, new ETS tables, registered processes, `:persistent_term` squatters, ExUnit state).

Add a deliberate leak-fixture test: a constructed mutant whose body intentionally mutates Application env, creates an unnamed ETS table, registers a process, sets a persistent_term key, and writes to ExUnit's OnExitHandler. After running it through the persistent worker, the next mutant's run starts with all of those reset to baseline. Catches silent leaks that "byte-identical outcomes" alone would miss.

**Step 3 — Test-file run filtering.** Persistent worker filters ExUnit to run only the selected test files per mutant via `ExUnit.configure(only_test_ids: ...)`.

Acceptance for step 3: demo_app outcomes byte-identical between mix worker and persistent worker for ALL test-selection cases (exact_line, enclosing_function, static_fallback, all_tests).

**Step 4 — Parallel persistent workers.** N concurrent persistent BEAMs through M17's `Mut.SandboxQueue`. Each worker is its own port + sandbox. Verify outcome identity at c=4 on demo_app and plug_crypto.

Acceptance for step 4: plug_crypto outcomes byte-identical between mix and persistent at c=4. demo_app outcomes byte-identical at c=4. M17's killed-survived stable-id-set equality bar applies.

**Step 5 — Fallback in-process recompile.** Until step 5, fallback mutants route to mix worker. Step 5 brings fallback into the persistent worker: the elixir-direct recompile path from PROMPT_16 (`84eaadf`) runs INSIDE the persistent BEAM rather than spawning a separate elixir process. The persistent worker patches the source, recompiles via `Kernel.ParallelCompiler.compile_to_path/2`, runs ExUnit, resets.

Acceptance for step 5: Decimal fallback under persistent worker remains 0 invalid (the M17 + PROMPT_16 baseline). Fallback survived-set is byte-identical between mix and persistent. demo_app fallback outcomes byte-identical.

**Step 6 — Crash detection + retry-then-fallback.** Port-exit signals attribute the mutant `:error`. Worker restarts in ~100ms (new BEAM, same sandbox). After N consecutive crashes (default 3), the sandbox falls back to mix worker for the remainder of the run. Configurable threshold via `--persistent-crash-threshold N` (advanced; default doesn't need tuning).

Acceptance for step 6: synthetic crash test (a mutant that intentionally calls `:erlang.exit(self(), :kill)`) produces `:error` status, worker restarts, subsequent mutants run normally. Crash-threshold test: N+1 consecutive synthetic crashes triggers mix-worker fallback for that sandbox.

**Step 7 — Public CLI flag + benches + docs.** Promote `--worker-type mix|persistent` to public CLI. Default stays `mix` for first v1.7 release. Add `e2e_persistent` verify layer that exercises demo_app schema + fallback under persistent worker. Run the smoke benchmarks at c=4: demo_app, plug_crypto, Decimal under both worker types. Update BENCHMARKS.md with side-by-side comparison. CHANGELOG v1.7 entry (including the Elixir 1.18+ requirement bump).

Acceptance for step 7: all 8 v1.6 verify layers green AT v1.6 default (mix). New `e2e_persistent` layer green. BENCHMARKS table shows mix vs persistent at c=4 across all three targets with documented timing variance.

### Acceptance gates (whole milestone)

- All 8 v1.6 layers + `e2e_persistent` green at `--worker-type mix` (default).
- `--worker-type mix` remains fully supported and is the default.
- demo_app outcomes byte-identical between worker types at c=1 and c=4.
- plug_crypto outcomes byte-identical between worker types at c=4.
- Decimal: same survived stable-id set between worker types. Killed/timeout timing flaps documented separately and accepted as variance, not regression.
- Decimal fallback under persistent: 0 invalid (matching M17 baseline).
- demo_app per-mutant median <50ms under persistent worker (the V17 schema acceptance).
- Decimal wall-clock under persistent at c=4 improves materially over M17's 11 min. **Do NOT hard-gate on ≤2 min**; the timeout-mutant lower bound is ~5.25 min. Document the actual number.
- Reset-hook leak fixture passes (intentional leaks proven cleaned).
- mutalisk's `mix.exs` requires `>= 1.18.0`. CHANGELOG notes the bump.

### Subagent brief

The single highest-risk surface:

**Step 2's reset hooks.** Silent state leaks between mutants are the single biggest correctness risk for persistent workers. The leak fixture must be aggressive — multiple state vectors mutated by ONE constructed mutant, then verified clean before the next. If reset misses a vector, the next mutant's behavior depends on the previous mutant's residue. That's worse than a slow run; it's wrong results that look right.

Lower-risk but worth attention:

- **Step 3's test-file filtering** uses `ExUnit.configure(only_test_ids: ...)` which is stable from Elixir 1.18+. The minimum-version bump in step 1 makes this the supported primary path; no fallback needed.
- **Step 5's in-process recompile.** `Kernel.ParallelCompiler.compile_to_path/2` running inside the persistent BEAM may interfere with the BEAM's already-loaded modules. Test this against demo_app fallback first; if module-conflict warnings or recompile failures appear, the in-process path may need to spawn a transient compile process even within the persistent BEAM.

### Out of scope for M19

- Persistent worker as default (stays `mix` in v1.7; flip after follow-up validation).
- Reducing per-mutant timeout below 60s.
- Changing timeout classification semantics.
- Cross-run state persistence.
- New mutators.
- Coverage default flip.
- Per-test-case coverage attribution.
- Oracle/schema build Mix bypass.
- Mutation semantics or stable_id input changes.
- Wrapper guard schemata.
- Supporting Elixir < 1.18.

### Recommended commit pacing

Exactly 7 commits, one per step. Each commit must pass `bin/verify` at all 9 layers (8 v1.6 + e2e_persistent once added). Steps 1-6 may keep the public flag undocumented; step 7 promotes it.

# Out of scope for v1.7 (do not let it sneak in)

- Persistent worker as default. Stays opt-in for first v1.7 release.
- New mutators (any kind).
- Coverage default flip (still opt-in even after v1.7).
- Per-test-case coverage attribution.
- Oracle/schema build Mix bypass.
- Persistent worker for oracle/schema build phases (those are one-shot; persistent doesn't help).
- Cross-run state persistence (v2).
- Wrapper guard schemata (v2).
- Reducing 60s per-mutant timeout (touches semantics, separate decision).
- Mutation semantics or stable_id input changes.

`--worker-type mix` is permanent — even after persistent becomes default in a v1.8+ follow-up, mix stays as the validated escape hatch and is regression-tested forever.

---

# v1.8 Milestones

v1.8's theme: **make persistent workers worth using, not just correct.**

v1.7 shipped persistent worker as opt-in supported with byte-identity proven on demo_app, plug_crypto, and Decimal. But BENCHMARKS shows persistent is currently SLOWER than mix on plug_crypto and Decimal at c=4. v1.7 delivered correctness without a perf win on real targets.

v1.8 closes that gap. Diagnose the dominant overhead, apply targeted optimizations, re-measure. The user-visible win is "persistent is faster than mix on real projects, not just demo_app."

**Default does NOT flip in v1.8** unless persistent beats mix on plug_crypto AND Decimal at c=4. Default flip is a separate v1.9+ decision based on v1.8's empirical results.

v1.8 is two milestones: M20 combines diagnostics with targeted optimization; M21 ships in-process fallback recompile only if M20 reveals fallback is dominant overhead.

## M20 — Persistent performance diagnostics + targeted optimization

**Goal:** identify the dominant per-phase overhead in persistent worker on real-world targets and apply targeted fixes that bring at least one of plug_crypto or Decimal to ≥1.5× faster than mix at c=4.

**Inputs:** v1.7 BENCHMARKS (current "persistent slower" baseline); `lib/mut/worker/persistent.ex`; `lib/mut/worker/persistent_runner.ex`; `lib/mut/worker/persistent_runner/reset.ex`; `lib/mut/metrics.ex`; existing `mutalisk` JSON extension key infrastructure.

### Phase A — Diagnostics (lands first)

Per-phase timing instrumentation inside the persistent worker:

- **Boot time per sandbox**: from port open to MUT_READY.
- **Project app startup time**: how long `Application.ensure_all_started/1` takes per app, summed.
- **Test file load time**: how long `Code.require_file/2` takes for the discovered test files.
- **Per-mutant ExUnit run time**: median, p95, count.
- **Reset hook time**: per-vector breakdown (Application env, ETS, processes, persistent_term, OnExit).
- **Filter lookup time**: time to translate requested files to `only_test_ids`.
- **Crash / restart / filter-miss fallback counts**: cumulative.
- **Memory dimension**: peak BEAM memory per persistent worker via `:erlang.memory(:total)` snapshots at boot, post-each-mutant, before-restart.

Surface in:
- `Mut.Metrics.Snapshot.persistent` block (host-side accumulation from worker reports).
- `mutalisk.persistent` extension key in Stryker JSON output.
- Terminal summary section "Persistent worker:" with per-phase median + total.

**Phase A acceptance:**
- Diagnostics shipped end-to-end. Stryker JSON validates. Terminal output readable.
- Initial bench at c=1/4 on demo_app, plug_crypto, Decimal documents the dominant overhead per target.
- Diagnostics overhead itself is <5% of run wall-clock.

### Phase B — Targeted optimization (based on Phase A findings)

Phase B's specific work depends on what Phase A reveals. Likely candidates ranked by hypothesis:

- **Most likely**: project app startup is dominant overhead per persistent boot. F2 (v1.7 followup) added `Application.ensure_all_started/1` for ALL `.app` files in `_build/mut_schema/lib/*/ebin/`. plug_crypto only needs `:plug_crypto`; Decimal only needs `:decimal`. **Fix**: start only the target project's apps + their declared `applications:` from mix.exs, not every `.app` in deps.
- **Possible**: reset_leaks/1 overhead exceeds savings on fast tests. **Fix**: profile each reset implementation, optimize the slow ones (NOT skip them — optimization, not conditional bypass).
- **Possible**: formatter overhead in the persistent-result protocol exceeds savings. **Fix**: design lighter in-BEAM result protocol that still preserves `killedBy`. Only if measurements indicate.
- **Possible**: ExUnit's iteration-N startup cost is non-trivial. **Fix**: TBD based on diagnostics.

Discovery cost optimization:
- Cache discovered app list per sandbox.
- Cache test file list per sandbox.

**Explicitly forbidden Phase B items:**
- Skipping reset vectors with dirty flags. Re-introduces the F2 failure mode (incomplete state reset → wrong results). Optimize implementations of reset hooks; do not conditionally bypass them.
- Disabling `Application.ensure_all_started/1` entirely. F2 proved this is required for correctness on plug_crypto-class projects. The fix is to start fewer apps, not zero apps.

**Phase B acceptance:**
- Persistent at default c=4 is **≥1.5× faster than mix** on at least one of plug_crypto or Decimal.
- demo_app remains faster (already true at v1.7).
- byte-identity preserved on all three targets — same Survived stable-id sets vs mix worker.
- `e2e_persistent` in bin/verify stays green.
- BENCHMARKS shows per-phase overhead before and after Phase B optimizations.

### Phase B fallback acceptance (if 1.5× isn't reachable)

If Phase B's optimizations don't reach 1.5× on any real target:
- Phase A diagnostics released regardless.
- BENCHMARKS documents residual overhead per target with root cause.
- M21 decision based on whether fallback is dominant overhead on Decimal-class projects.
- v1.8 ships as "diagnostics released, persistent stays opt-in, perf gap documented."

### Acceptance gates (whole milestone)

- All 9 v1.7 verify layers green at default (`--worker-type mix`).
- byte-identity preserved on demo_app, plug_crypto, Decimal between worker types.
- Phase A diagnostics shipped (non-negotiable).
- Phase B either reaches 1.5× on a real target OR clearly documents residual overhead with root cause.
- Memory pressure under persistent c=8 documented (don't ship if any target OOMs).

### Subagent brief

**Highest risk surface:** byte-identity regression. Phase B's optimizations touch the persistent worker's hot path. ANY change that affects what state the worker resets, what apps it starts, or how it reports results can cause silent outcome drift. The byte-identity check at the end of Phase B is load-bearing.

**Workflow discipline:** Phase A lands BEFORE any Phase B optimization. Diagnostics tell you what to optimize; optimizing without measuring is guessing.

**Don't optimize the wrong thing.** If Phase A shows boot time is 80% of overhead on plug_crypto, optimizing reset_leaks gives 0 user-visible win. Pick the dominant overhead per target; ignore the others until they become dominant.

### Out of scope for M20

- Default flip from `mix` to `persistent` (v1.9+ decision).
- In-process fallback recompile (M21, conditional).
- New mutators.
- Coverage default flip.
- Per-test-case coverage attribution.
- Oracle/schema build Mix bypass.
- Reducing per-mutant timeout below 60s.
- Cross-run state persistence.
- Skipping reset vectors with dirty flags (correctness hazard).
- Disabling Application.ensure_all_started (correctness hazard).
- Mutation semantics or stable_id input changes.

### Recommended commit pacing

5-7 commits.

1. Per-phase timing instrumentation in `Mut.Worker.Persistent` + `Mut.Worker.PersistentRunner`.
2. `Mut.Metrics.Snapshot.persistent` block + reporter integration + JSON `mutalisk.persistent` key + terminal display.
3. Initial bench measurements + BENCHMARKS Phase A table identifying dominant overhead per target.
4. Phase B optimization #1 (most likely: scoped app startup).
5. Phase B optimization #2 (driven by measurements).
6. Re-bench + BENCHMARKS Phase B table showing before/after per target.
7. Final verify + CHANGELOG + cleanup.

If Phase A measurements clearly show one optimization closes the gap, stop after step 4. Don't over-optimize for diminishing returns.

---

## M21 — In-process fallback recompile (conditional)

**Conditional milestone.** Run only if M20 Phase A measurements show fallback recompile is dominant overhead on Decimal-class projects. Otherwise defer indefinitely.

**Goal:** bring fallback mutants into the persistent worker, eliminating per-fallback-mutant child Mix process spawns.

### Deliverables (if executed)

- `:code.purge/1` + `:code.load_binary/3` flow inside the persistent BEAM with module-conflict handling.
- Source patch applied in-process, recompiled via `Kernel.ParallelCompiler.compile_to_path/2`, loaded into the persistent BEAM.
- On purge/recompile failure: restart persistent BEAM (v1.7 F4 phase 1's restart machinery) and rerun the mutant via mix-spawn fallback.
- Reset hooks extended to handle module-redefinition state.

### Acceptance gates

- byte-identity preserved on demo_app, plug_crypto, Decimal for fallback bucket.
- Decimal fallback wall-clock improves measurably.
- No increase in invalid/error mutants on any target.
- demo_app and plug_crypto fallback outcomes byte-identical between mix-spawn and in-process recompile.

### Decision criteria for executing M21

- M20 Phase A measurements show fallback overhead >25% of total wall-clock on Decimal at c=4.
- AND M20 Phase B optimizations alone don't close the v1.8 perf gate.

If either condition fails, M21 defers to v1.9 or later. v1.8 ships with M20 alone.

### Recommended commit pacing

3-4 commits if executed.

# Out of scope for v1.8 (do not let it sneak in)

- Default flip from `mix` to `persistent`. Decision deferred to v1.9+.
- New mutators (any kind).
- Coverage default flip.
- Per-test-case coverage attribution.
- Oracle/schema build Mix bypass.
- Cross-run state persistence (v2).
- Wrapper guard schemata (v2).
- Reducing 60s per-mutant timeout.
- Mutation semantics or stable_id input changes.
- Skipping reset vectors via dirty flags (correctness hazard reintroduced from v1.7 F2).
- Disabling `Application.ensure_all_started/1` for project apps.

`--worker-type mix` remains permanent regardless of v1.8 perf outcomes.

---

# v1.9 Milestones

v1.9's theme: **mature persistent worker, expand mutation surface, validate against the Elixir ecosystem.**

v1.8 delivered persistent worker speedups (2.04× plug_crypto, 1.99× Decimal at c=4 with `--test-timeout-ms 10000`). v1.7 + v1.8 only validated 3 projects. v1.9 matures persistent-worker operations and lands a narrow new literal mutator surface without changing defaults.

**Default `--worker-type` does NOT flip in v1.9.** That's v1.10 territory, gated on expanded validation results.

**Default `--selection` does NOT flip in v1.9.** Coverage remains opt-in until expanded real-project validation proves the interaction with persistent workers and the expanded mutation surface.

v1.9 lands two milestones. M22 adds reliability, observability, and configuration. M23 introduces opt-in body-context literal mutators. Real-world validation and default flips move to v1.10+.

## M22 — Persistent reliability + observability + config + guide

**Goal:** make persistent worker operationally boring, expose the diagnostics M20 already collects, document the user contract.

**Deliverables:**

- **`--test-timeout-ms N` flag + `config :mut, test_timeout_ms: N`.** Default 10_000 (v1.8's value). Plumbs to both mix-spawn `--timeout` and persistent runner ExUnit config. Reported in terminal and `mutalisk.test_timeout_ms` JSON key. Users with legitimately slow tests have a one-flag opt-out.
- **Persistent metrics surfaced in summary always when persistent is active.** M20 collects restart count, in-process fallback compile-error count, filter-miss count. M22 promotes these to terminal display in the existing "Persistent worker:" section.
- **Single explicit warning threshold.** At run end, if `--worker-type persistent` AND any of: filter-miss rate > 25%, crash rate > 10%, in-process fallback compile-error rate > 5% — emit a one-line warning suggesting `--worker-type mix`. No auto-fallback, no auto-mode-switching. Just a hint.
- **Coverage + persistent interaction validation.** Add an integration test asserting `--selection coverage_with_static_fallback --worker-type persistent` produces byte-identical outcomes vs `--selection static --worker-type mix` on demo_app and plug_crypto. Currently UNTESTED; this closes a real silent-drift risk before v1.10 considers default flips.
- **Regression fixture for Application.start/2 + named ETS.** Add `test/fixtures/overlay_cases/app_start_callback/` mirroring the plug_crypto F2 root cause. Lock in the v1.7 fix; future code changes can't regress it silently.
- **`docs/PERSISTENT_WORKER_GUIDE.md`** (new). User-facing doc covering: when to use persistent, what project shapes work, what doesn't (NIF projects, tests with global GenServer state, etc.), how to interpret persistent metrics, when to fall back to `--worker-type mix`. Replaces scattered CHANGELOG warnings with a single canonical reference.

**Acceptance gates:**
- All 9 v1.9 verify layers green at default.
- `--test-timeout-ms` flag works on both worker types.
- Persistent metrics shown in terminal output when `--worker-type persistent` is active.
- Warning threshold triggers correctly on synthetic test fixtures.
- Coverage + persistent interaction byte-identical on demo_app and plug_crypto.
- PERSISTENT_WORKER_GUIDE.md committed.

**Out of scope for M22:**
- Default flip of `--worker-type` (v1.10).
- Default flip of `--selection` (v1.10+).
- New mutators (M23).
- Real-world validation expansion (M24).

**Recommended commit pacing:** 4-5 commits.

---

## M23 — Body-context literal mutators

**Goal:** introduce mutation targets in function-body literals. v1's mutator set covers operators and dispatches but leaves literals untouched in body positions. Adds two focused mutators with low equivalent-mutant rate.

**Scope:** narrow. Only integer and boolean literals in body positions. Float, string, atom, list, map, tuple deferred to v2 alongside the lean env walker.

**Deliverables:**

- **`Mut.AstWalk.body_literal_candidates/2`**: walker that emits `%AstCandidate{}` for integer and boolean literals in function-body context. Uses existing `env_context` field; populates with `nil` (body) and skips when `:guard` or `:match`.
- **Body-context detection**: walker tracks whether current AST position is inside a `def`/`defp`/`defmacro`/`defmacrop` body, NOT inside `when` (guard), NOT inside pattern positions (LHS of `=`, function head args, `case`/`with`/`fn` clause heads), NOT inside `quote`/`unquote`/`unquote_splicing`. The existing `Mut.AstWalk` infrastructure tracks `ast_path`; reuse for context detection.
- **`Mut.Mutator.IntegerLiteral`**:
  - Targets: `:dispatch`-equivalent for body context; specifically `targets/0` returns `[:body_literal]` (new target type).
  - Replacement table:
    - `0 → 1`
    - `1 → 0`
    - `n → 0` (for n > 1 or n < 0)
    - `n → n + 1` (avoiding overflow concerns; document limit)
  - `applicable?/2`: requires `ctx.env_context == nil` AND `ctx.engine == :fallback`.
  - `compatible?/2`: matches body literal candidates with integer values.
- **`Mut.Mutator.BooleanLiteral`**:
  - Targets: `[:body_literal]`.
  - Replacement table: `true → false`, `false → true`.
  - Same applicable/compatible discipline as IntegerLiteral.
- **`Mut.Plan` extension**: `:body_literal` added to `target` enum. Orchestrator routes body-literal candidates through the fallback engine, gated by `--enable body_literal`.
- **Stable ID input extension**: body-literal mutations need to be stably-identified. Existing `(file, span, mutator, kind, original_dispatch)` tuple works if `original_dispatch` for body literals is `"<literal_value>"`. Verify and pin format.
- **Schema routing deferred**: schema placement requires the literal walker and placer to agree on AST shape. The v1.9 walker uses parser `literal_encoder` metadata; the existing placer uses bare-literal AST, so fallback routing avoids global stable-id churn.
- **Demo_app fixture extension**: add a small integer-literal mutation site (e.g., a function returning `0` as a default) and a boolean-literal site to `arith.ex` or a new `literals.ex`. Update fixture tests to actually catch the mutation.
- **Golden mutation list update**: regenerate `test/golden/mutations/*.json` for fixture files now containing body literal mutants.

**Acceptance gates:**
- All 9 v1.9 verify layers green at default.
- demo_app fixture mutant count grows by the expected number (literals in fixture × replacements per literal).
- byte-identity preserved between mix and persistent for body-literal mutants.
- Plug_crypto produces additional body-literal mutants; stable_ids deterministic across runs.
- Equivalent-mutant rate documented (expected: high for `n → n+1` on truly arbitrary integers; lower for `0 → 1`).

**Out of scope for M23:**
- Float, string, atom, list, map, tuple literal mutators (v2 with env walker).
- Pattern-position literal mutations (different semantic surface).
- Function-call deletion (deferred indefinitely).
- Return-value replacement (deferred indefinitely).
- Variable mutations (v2).

**Recommended commit pacing:** 4-6 commits.

1. Walker extension for body-literal context detection.
2. `Mut.Mutator.IntegerLiteral` + tests.
3. `Mut.Mutator.BooleanLiteral` + tests.
4. Orchestrator routing + Plan target enum.
5. Fallback routing integration + demo_app fixture extension.
6. Golden mutation lists regenerated.

---

## M24 — Body-literal real-world validation (v1.10 candidate)

**Goal:** validate opt-in body literal mutation on real projects before adding more literal types or changing defaults.

**Deliverables:**

- **Body-literal validation matrix**: run demo_app, plug_crypto, and Decimal with and without `--enable body_literal`; capture additional mutants, killed/survived/timeout/invalid deltas, fallback wall-clock delta, and noisy/equivalent survivor samples.
- **Real-world target expansion**: validate on additional OSS targets beyond demo_app/plug_crypto/Decimal. Suggested set:
  - `nimble_options` — small, simple validation. Baseline.
  - `gettext` — compile-time macros. Tests schema build robustness on macro-heavy code.
  - `ecto` — Ecto.Query macro, schema generation. Tests both schema build AND persistent's reset hooks (Ecto.Repo state).
  - `mox` — module-replacement mocking. The kind of test pattern that could expose persistent's reset hooks. CRITICAL TEST.
  - **`jason` (StreamData target)** — property-based tests via StreamData. Mutation testing on StreamData is intrinsically non-deterministic (different generator inputs each run). Document this as a known limitation; don't gate on byte-identity for StreamData targets. Treat as "informational" benchmark.
- **Validation matrix per target**: run `--worker-type mix --selection static`, `--worker-type persistent --selection static`, and the same persistent run with `--enable body_literal` at c=4. Capture wall-clock, kill rate, byte-identity status, invalid rate, and fallback cost.
- **`docs/PERSISTENT_WORKER_GUIDE.md` extension**: per-target findings, unsupported pattern catalog (if any surface).
- **BENCHMARKS.md "v1.10 body-literal validation" section**: full matrix of targets × worker × body-literal enablement. Compare to v1.9 baseline.
- **v1.10 default-flip gate documented**: PLAN.md gains a forward-looking section pinning the criteria for flipping `--worker-type` default in v1.10. Specifically: ≥4 of 5 new OSS targets clean (byte-identical, persistent faster or comparable); zero new unsupported-pattern categories affecting common project shapes; persistent ≥1.5× faster than mix at default concurrency on at least plug_crypto, Decimal, AND 2 of M24's new targets.

**Acceptance gates:**
- All 9 v1.9 verify layers green at default.
- Existing non-body-literal stable IDs unchanged when `--enable body_literal` is not used.
- `--enable body_literal` produces zero invalid body-literal mutants on reference targets.
- Additional killed/survived/timeout deltas and fallback cost are documented.
- Clear recommendation documented: keep opt-in, enable by default, or trim replacement table.
- ≥5 OSS targets validated; matrix documented.
- PERSISTENT_WORKER_GUIDE.md gains target-specific notes.
- Any unsupported patterns documented.

**Out of scope for M24:**
- Default `--worker-type` flip.
- Default `--selection` flip.
- New literal types beyond integer/boolean.
- Reliability work already covered by M22.

**Subagent brief:**

The riskiest target is `mox`. Module-replacement mocking writes new bytecode for mocked modules at runtime, then restores. Persistent worker's reset hooks may not catch `:code` server state for mocked-and-restored modules. If mox testing diverges between worker types, that's a real find — document and add to PERSISTENT_WORKER_GUIDE's unsupported patterns.

The least risky is `nimble_options`. Run that first to validate the harness; if it works, scale to others.

**StreamData targets (jason)** are intrinsically non-deterministic. Mutation outcomes vary across runs because generator inputs vary. Two approaches:
1. Pin a StreamData seed via `ExUnit.start(seed: N)` and `:rand.seed/2` configuration, then accept that one fixed seed defines "byte-identical."
2. Document the variance and report the run as "informational."

Pick approach 1 if pinnable; fall back to approach 2 otherwise. Either way, StreamData target results don't gate v1.9 acceptance.

**Recommended commit pacing:** 5-7 commits.

1. Validation matrix harness extension.
2. Body-literal benches: demo_app, plug_crypto, Decimal.
3. Per-target benches: nimble_options, gettext (and PERSISTENT_WORKER_GUIDE entries).
4. Per-target benches: ecto, mox (and any unsupported patterns documented).
5. StreamData target (jason) with documented variance.
6. BENCHMARKS.md v1.10 body-literal validation section.
7. Body-literal default/opt-in recommendation.

---

# v1.10 default `--worker-type` flip gate (forward-looking)

`--worker-type` default flips from `mix` → `persistent` in v1.10 IF AND ONLY IF:

- v1.10 validation covers ≥4 of ≥5 new OSS targets cleanly (byte-identical, persistent faster or comparable).
- Zero new unsupported-pattern categories surface during validation that affect common Elixir project shapes (Phoenix-style, Ecto-style, GenServer-heavy).
- `--worker-type mix` remains the documented and tested escape hatch.
- Persistent is faster than mix at default `--concurrency` on at least plug_crypto, Decimal, AND 2 of M24's new targets.

If validation surfaces unsupported patterns affecting common project shapes, default stays `mix` and v1.10's scope shifts to addressing those patterns.

# Out of scope for v1.9 (do not let it sneak in)

- Default `--worker-type` flip (v1.10).
- Float, string, atom, list, map, tuple body-literal mutators (v2 with env walker).
- Pattern-position literal mutators (v2).
- Variable mutators (v2).
- Function-call deletion / return-value replacement (deferred indefinitely).
- New CLI flags beyond `--test-timeout-ms`.
- Cross-run state persistence (v2).
- Wrapper guard schemata (v2).
- Mutation semantics changes.
- Skipping reset vectors via dirty flags.
- Disabling `Application.ensure_all_started/1`.
- Auto-fallback / auto-mode-switching for persistent worker (just warning thresholds).

---

# v1.10 Milestones

v1.10's theme: **validate everything against the Elixir ecosystem, then decide on defaults.**

v1.9 deferred the OSS validation matrix because external-repo probing was sandbox-blocked. v1.10's job is to actually run that matrix and use the data to make two decisions: body-literal default policy + persistent worker default-flip.

**One bench cycle answers both questions.** Running 5+ OSS targets × `{mix, persistent}` × `{baseline, body_literal}` produces:
- Body-literal kill rate per target.
- Equivalent-mutant rate signal.
- Fallback wall-clock impact for body literals.
- Persistent vs mix wall-clock per target.
- Coverage selection field validation on OSS targets (the v1.9-planned default flip to `coverage_with_static_fallback` did not land; default remains `:static` per cli.ex:276; M25 still measures coverage selection's behaviour against the matrix).
- Coverage + body_literal interaction validation.
- M22 warning threshold field-tuning data.

v1.10 is **two milestones** (not four). M25 runs the matrix and decides body-literal scope. M26 uses the same matrix data to decide persistent default-flip.

## M25 — Validation matrix + body-literal decisions

**Goal:** run the OSS validation matrix that v1.9 M24 deferred; use the data to decide body-literal default policy and routing.

**Inputs:** `bench/run.sh` harness (M24 ready); pinned target SHAs (M25's first task to capture); v1.9 PLAN/HLD/CHANGELOG; v1.9's `mutalisk.persistent` JSON metrics block.

### Phase A — Pin target SHAs

Each OSS target needs a pinned commit SHA for reproducibility:

- `nimble_options` — small validation library, baseline correctness.
- `gettext` — compile-time macros, schema-build robustness.
- `ecto` — Ecto.Query macros, schema generation, persistent reset hooks tested against Ecto.Repo state.
- `mox` — module-replacement mocking. Highest-risk target for persistent's `:code` server reset.
- `jason` — StreamData property tests. Non-deterministic; treat as informational.
- (Optional) `plug` — if budget allows, real-world Phoenix-shape testing.

For each: `git ls-remote <repo> | grep <stable-tag-or-main>` → pin SHA in `bench/run.sh`'s target table. SHAs committed; runs reproducible.

### Phase B — Run the matrix

For each target, execute (sequentially or batched):

1. `bench/run.sh --target <t> --concurrency 4 --worker-type mix` (baseline)
2. `bench/run.sh --target <t> --concurrency 4 --worker-type persistent` (persistent baseline)
3. `bench/run.sh --target <t> --concurrency 4 --worker-type mix --enable-body-literal` (mix + body literals)
4. `bench/run.sh --target <t> --concurrency 4 --worker-type persistent --enable-body-literal` (persistent + body literals)

Estimated bench time: 6 targets × 4 modes × 30-90 min/target = ~12-18 hours. Run overnight or distributed.

For each run, capture in `bench/results/`: Stryker JSON, terminal output, wall-clock per phase, `mutalisk.persistent` block.

### Phase C — Analyze + decide

For each target, compare:

**Byte-identity check (mix vs persistent at same body_literal mode)**:
- Same total mutant count?
- Same Survived stable_id set (MapSet.equal?)?
- Same Killed stable_id set (modulo V17 timeout-flap acceptance)?

If any deterministic target shows drift > V17 acceptance: PERSISTENT_WORKER_GUIDE.md gains an "unsupported pattern" entry; investigate the drift source.

**Body-literal impact (baseline vs body_literal at same worker)**:
- Mutant count delta (number of new body-literal mutants).
- Kill rate of new mutants (killed / generated).
- Equivalent-mutant rate (estimate: surviving mutants whose math is trivially indistinguishable).
- Fallback wall-clock contribution (body literals route through fallback engine in v1.9 M23).

**Coverage selection validation** (the v1.9-planned default flip to `coverage_with_static_fallback` did NOT land; default `--selection` remains `:static` per `lib/mut/cli.ex:276`. M25 measures coverage selection's behaviour as a forward-looking signal — a future flip is gated on this data):
- Coverage selection adds time on small projects with auto-fallback; should reduce time on larger projects.
- Document any project where coverage selection produces false survivors or false kills (a real silent-drift bug if surfaced).

**Coverage + body_literal interaction**:
- Verify the M22 e2e_persistent assertion generalizes to OSS targets.
- Body-literal mutants under coverage selection should map to tests that hit the literal's line.

**M22 warning threshold tuning**:
- Did any target trip the warning hint (filter-miss > 25%, crash > 10%, fallback compile-error > 5%)?
- If a hint fired but the run was actually fine: threshold too tight, raise it.
- If no hint fired but the run had real issues (high fallback count, frequent restarts): threshold too loose, lower it.

### Phase D — Decisions output

Two decisions encoded in M25's final commit:

**Decision 1: body-literal default policy**

Three possible outcomes:
- **Default-on** if: average kill rate ≥60% across deterministic targets AND equivalent-mutant rate <20% AND zero invalid body-literal mutants. Update `Mut.Cli` default `:enable` to include `:body_literal`.
- **Trim table** if: equivalent-mutant rate is dominant noise (specifically: `n → n+1` produces survivor rate >50% across multiple targets). Drop `n → n+1` from `Mut.Mutator.IntegerLiteral` replacement table; keep `0 → 1`, `1 → 0`, `n → 0`. Re-run matrix on subset of targets to validate.
- **Keep opt-in** if: any target shows >5% invalid body-literal mutants OR `mox`/`ecto` shows persistent-specific drift. CHANGELOG documents the limitation.

**Decision 2: body-literal routing decision**

Two possible outcomes:
- **Stay fallback** if: body-literal contribution to total wall-clock <15% on the largest target. v1.10 doesn't change routing.
- **Migrate to schema (deferred to v1.11+)** if: fallback cost ≥15% AND Decision 1 = default-on. v1.10 documents the migration as a v1.11 milestone scope; doesn't ship the migration code (stable_id migration is too big to fold into M25).

### Acceptance gates (whole milestone)

- All 9 v1.9 verify layers green at default after M25's changes (default may flip per Decision 1).
- BENCHMARKS.md gains "v1.10 validation matrix" section with per-target × per-mode table.
- PERSISTENT_WORKER_GUIDE.md updated with target-specific findings + any unsupported patterns.
- CHANGELOG documents Decision 1 outcome.
- If Decision 2 = migrate-to-schema: PLAN.md gains a v1.11 milestone scoping the stable_id migration.
- bench/results/ has all 24+ matrix runs committed (small JSON files; valuable historical record).

### Out of scope for M25

- Schema-routing migration code (deferred to v1.11+ if Decision 2 demands it).
- Persistent default-flip (M26's job, same matrix data).
- New mutators beyond M23's body literals.
- New CLI flags.
- Mutation semantics changes.
- Coverage caching (still v2).

### Subagent brief

**Highest-risk targets and what to look for**:

- **`mox`**: module-replacement mocking writes new bytecode at runtime, then restores. Persistent's reset hooks may not catch all `:code` server state. Run mix vs persistent first; any drift = unsupported pattern documented immediately.
- **`ecto`**: schema-generation macros + Ecto.Repo state. Persistent's reset hooks need to handle Ecto.Repo's process-tree (DBConnection pool, etc.). Run small Ecto first if budget allows.
- **`jason` (StreamData)**: pin StreamData seed via `ExUnit.start(seed: N)` before running; otherwise mutation outcomes are non-deterministic. Document the pinned seed in BENCHMARKS as the reproducibility input. If StreamData seed-pinning doesn't fully stabilize outcomes, fall back to "informational target" framing.

**Bench discipline**:
- Run each target's `mix` baseline FIRST (gold standard for byte-identity comparison).
- THEN run persistent baseline; compare to mix.
- THEN run mix + body_literal; compare to mix baseline (mutant count delta + new survivors).
- THEN run persistent + body_literal; compare to mix + body_literal (byte-identity check across worker types).

This four-step-per-target sequence isolates regressions: any drift between steps 1-2 is persistent-related; any drift between steps 1-3 is body-literal-related; any drift between steps 3-4 is persistent + body_literal interaction.

**Don't pre-commit decisions before the data**. The decision criteria above are predicates evaluated against the matrix data. Empirics decide.

### Recommended commit pacing

5-7 commits.

1. Pin target SHAs in `bench/run.sh`.
2. Run matrix; commit per-target raw results.
3. BENCHMARKS.md "v1.10 validation matrix" section + analysis tables.
4. Decision 1 implementation: keep opt-in / trim table / default-on (whichever applies).
5. Decision 2 documentation: stay fallback OR v1.11 migration scope written into PLAN.
6. PERSISTENT_WORKER_GUIDE.md updates + CHANGELOG v1.10 entry.

If matrix surfaces unsupported patterns: additional commits documenting them (one per pattern), no code changes (those are v1.11+).

---

## M26 — Persistent worker default-flip decision

**Goal:** apply the v1.10 default-flip gate (already documented in PLAN.md after M24) using the M25 matrix data.

**Inputs:** M25's matrix results; v1.10 default-flip gate criteria.

### Phase A — Apply gate criteria

The v1.10 default-flip gate:

- ≥4 of 5 new OSS targets clean (byte-identical, persistent ≥ comparable).
- Zero new unsupported-pattern categories surface during M25 that affect common Elixir project shapes.
- `--worker-type mix` remains the documented and tested escape hatch.
- Persistent ≥1.5× faster than mix at default `--concurrency 4` on plug_crypto, Decimal, AND 2 of M25's new targets.

Evaluate each criterion against M25's data. Don't run new bench cycles; reuse M25's results.

### Phase B — Three possible outcomes

**Outcome 1: Flip default to persistent.** All gate criteria met.
- Change `Mut.Cli` default for `--worker-type` from `:mix` to `:persistent`.
- Update CHANGELOG with rationale and explicit "use `--worker-type mix` for sequential or for projects that need it."
- Update PERSISTENT_WORKER_GUIDE: persistent is now the default; sections about "when to opt in" become sections about "when to opt out."
- Update README.
- v1.10 ships as "default-faster mutation testing."

**Outcome 2: Keep mix default but document persistent as production-ready.** Gate criteria mostly met; one or two targets have caveats but overall picture is healthy.
- No code change.
- CHANGELOG: explicit "persistent is now production-ready opt-in."
- PERSISTENT_WORKER_GUIDE: tightened language on supported project shapes.
- v1.10 ships as "extended docs + opt-in confidence."

**Outcome 3: Defer flip; document patterns persistent doesn't yet handle.** Gate criteria not met.
- No default change.
- PERSISTENT_WORKER_GUIDE: detailed documentation of unsupported patterns.
- PLAN.md gains v1.11 milestones scoped to address the unsupported patterns.
- v1.10 ships as "validation honest, fixes scoped for v1.11."

### Acceptance gates

- M25's matrix data exists and is committed.
- Gate criteria evaluated against the data; outcome chosen with documented rationale.
- CHANGELOG records the outcome.
- All 9 verify layers still green at the chosen default.
- If Outcome 1: e2e_persistent layer renamed or supplemented to validate the new default.

### Out of scope for M26

- New bench runs (use M25's data).
- Schema-routing migration (M25's Decision 2).
- New mutators.
- v1.11 work.

### Recommended commit pacing

2-3 commits.

1. Outcome decision: code change (Outcome 1) OR doc update (Outcomes 2, 3).
2. CHANGELOG + PERSISTENT_WORKER_GUIDE updates.
3. (Outcome 3 only) PLAN.md v1.11 milestone scoping.

---

# v1.11 milestones (M26 confirmed Outcome 3)

M26 evaluated the v1.10 default-flip gate against M25's matrix data
and selected **Outcome 3: defer flip; scope persistent-pattern
fixes for v1.11**. The persistent worker remains opt-in. v1.11
takes on the unsupported-pattern fixes M25 surfaced AND restarts
mutator-catalog growth, which v1.9 and v1.10 both deferred.

**Theme**: widen real-world validation while closing the biggest
persistent correctness gaps. Three releases in a row without a new
mutator weakens the value prop; one narrow fallback-safe mutator
ships in v1.11.

**Upstream Elixir heredoc fix is NOT a milestone.** It is unlikely
to land in the v1.11 timeframe; it lives as a tracking note in
CHANGELOG and a `# TODO` comment at the workaround site. When
upstream ships, the revert is a single PR, not a milestone.

## v1.11 scope (committed)

Four committed milestones. Order matters: cheap correctness wins
first, then the spike, then the data-dependent fix.

**M27 — OSS validation harness expansion + drift observability.**
v1.10's lesson: 3 reference targets (demo_app, plug_crypto, Decimal)
hide entire bug classes. Make real-life coverage a permanent asset,
not a one-off bench cycle.
- Pin ≥5 additional OSS targets beyond M25's set. Candidates:
  `plug`, `phoenix_html` or `phoenix_template`, `telemetry_metrics`,
  `broadway` or `oban` if locally runnable, `finch` or `mint`.
- Each target classified as `clean` / `drift` / `unrunnable` /
  `informational`. Per-target prep documented in `bench/run.sh` +
  BENCHMARKS.md.
- **Drift observability**: a small analysis command/script that
  diffs mix-vs-persistent stable-id status partitions and
  auto-buckets drift by heuristic (compile-error class, mox-class,
  ecto-class, parse-class, …). Hand-classification was tractable
  for 5 targets; it does not scale to 10+.
- **Persistent boot-time warning** for known-bad target classes:
  if persistent boot detects mox / ecto / gettext-class signatures,
  emit a one-line "consider `--worker-type mix`" hint at startup.
  Closes the user-experience gap M25's drift findings opened.

Acceptance:
- ≥5 new pinned targets benched + classified.
- No future default-flip decision relies only on demo_app /
  plug_crypto / Decimal.
- Drift bucketing tool exits 0 with a per-bucket count table on
  M25's existing data.
- Persistent boot warning fires correctly on mox / gettext;
  silent on plug_crypto / Decimal / nimble_options.

**M28 — `Mox.Server` reset hook.** Cleanest correctness fix in the
v1.11 set; ships first to bank a win regardless of M29's spike
outcome.
- Add a Mox-aware reset hook to persistent runner. Purges
  `Mox.Server`'s mock registry between mutants. Tolerate
  Mox-not-loaded targets (no-op).
- Acceptance: mox baseline persistent drift drops to V17
  timeout-flap acceptance. Zero regression on demo_app /
  plug_crypto / Decimal. If the server's state model makes a
  surgical reset infeasible, formally document mox-class as
  mix-only with the exact reason in PERSISTENT_WORKER_GUIDE.

**M29 — Persistent recompile isolation spike.** Ecto and
nimble_options drift may share a root cause: persistent's
in-process recompile (`Code.compile_file/1`) leaks compile-time
state mix-spawn doesn't. Spike before committing to per-target
fixes — isolation may subsume both M30 (Ecto) and the
nimble_options parse-class residual at once.
- Three modes to compare on `nimble_options` and `ecto`:
  - Current persistent in-process compile.
  - Helper-process compile (short-lived child process for the
    recompile, persistent BEAM keeps test-load state warm).
  - Mix-spawn fallback (baseline; already implemented).
- Measure: drift partition vs mix-spawn, wall-clock cost,
  memory footprint, fallback rate.
- **Question**: is `Code.compile_file/1` fundamentally the wrong
  primitive vs `Kernel.ParallelCompiler.compile_to_path/2`?
- Output: a written decision doc — proceed with helper-process
  isolation in v1.12, or attack drift target-class-by-target-class
  via M30. Spike does NOT ship the chosen path; it only chooses.
- Acceptance: decision doc committed under
  `docs/spikes/M29_recompile_isolation.md`. Three-mode comparison
  table on nimble_options and ecto. Recommendation explicit.

**M30 — Ecto warm-state closure.** Sequenced after M29 because the
spike's outcome may eliminate most of this work. If M29 picks
helper-process isolation, M30 shrinks to "validate the spike fix
clears Ecto drift."
- M25 ecto v3.13.6 showed 22.4% drift split between (a)
  RuntimeError-recovery via warm BEAM (~115 mutants — persistent
  hides errors mix-spawn surfaces) and (b) false-positive kills
  via leaked Ecto.Query planner cache (~55 mutants).
- If isolation insufficient: implement target-specific resets —
  reset ETS-backed compile caches (planner cache, schema metadata)
  + Repo process-tree teardown between mutants.
- If isolation closes most drift: validate residual drift is V17-
  acceptance and document.
- Acceptance: ecto persistent drift materially reduced (target:
  V17 timeout-flap acceptance). If still unsafe, PERSISTENT_WORKER
  _GUIDE explicitly classifies Ecto-class projects as mix-only with
  the exact failure modes.

## v1.11 stretch (commit only if committed milestones land with budget)

**M31 — Gettext compatibility decision.** Do NOT block v1.11 on
this if it turns into compiler plumbing.
- Path (i): try loading tests under a real
  `Kernel.ParallelCompiler` parent. If clean and cheap, ship it.
- Path (ii): formally exclude gettext-class compile hooks as
  mix-only. Document why; tag `--worker-type persistent` to
  refuse-and-fallback-with-warning when gettext is detected
  (already covered by M27's boot warning).
- Acceptance: gettext persistent boots and runs with measured
  drift, OR exclusion is explicit, tested, and documented.

**M32 — Affected-test selection spike.** A spike, not a
committed optimization. Silent-survivor risk dominates.
- For schema mutants: map mutant module/function/line → covering
  tests via existing coverage data.
- For fallback mutants: include compile-connected dependents +
  tests covering changed file/function. Open question whether
  affected-tests interacts with the persistent in-process
  fallback's compile-connected dependents logic — answer this
  inside the spike.
- Compare against `static` and `coverage_with_static_fallback` on
  demo_app, plug_crypto, nimble_options, jason.
- **Sharpened kill criterion**: ANY silent-survivor delta on ANY
  target kills the optimization. "Mostly byte-identical" is not
  acceptable — survivor drift is correctness regression
  masquerading as a perf win. At v1.x maturity correctness
  dominates.
- Acceptance: if byte-identical (zero silent-survivor delta) on
  reference targets + ≥2 OSS targets, promote to v1.12
  implementation milestone. Otherwise, document and shelve.

**M33 — Comparison-operator boundary mutator.** Restart catalog
growth with one narrow, fallback-safe addition.
- New schema mutator `Mut.Mutator.ComparisonBoundary`: in body
  context only, mutate `<` ↔ `<=`, `>` ↔ `>=`. Off-by-one boundary
  errors are a high-value mutation class with documented low
  equivalent-mutant rate in arithmetic-heavy code.
- Routes via the existing schema engine (operator dispatch already
  supported by tracer oracle). No env walker required.
- Atoms / strings / maps / lists stay deferred to v2 with the
  env walker.
- Acceptance: mutator unit-tested + golden_oracle/golden_instrument
  layers green. Re-runs on plug_crypto + Decimal show non-zero
  new mutants with kill rate ≥60% on reference targets.
- Skip M33 if M27-M30 consumes the v1.11 budget; defer to v1.12.

## v1.11 default-flip gate (revised)

Default `--worker-type` flips from `mix` → `persistent` iff:
- M28 closes mox-class drift to V17 timeout-flap acceptance, AND
- M30 closes ecto-class drift to V17 timeout-flap acceptance, AND
- gettext-class targets are either fixed (M31 path i) or
  formally documented as `--worker-type mix` only (M31 path ii).

M29's spike output may change this gate's wording in v1.12 if it
recommends helper-process isolation over per-target resets. The
default-flip itself is **not a v1.11 goal**; it is an outcome only
if the gate happens to be met. v1.11 ships even if all three
conditions fail (worker stays opt-in; default stays `mix`).

## v1.11 horizon (not v1.11 scope)

- **Body-literal schema-routing migration** (M25 Decision 2 candidate).
  Re-evaluate after Decision 1 ever flips default-on; until then
  the routing decision stays "fallback".
- **Helper-process recompile isolation implementation**, if M29
  spike recommends it. v1.12 candidate.
- **Affected-tests selection implementation**, if M32 spike
  promotes. v1.12 candidate.
- **Env walker** (the long-deferred v2 architecture work). Unblocks
  float/string/atom/list/map/tuple body literals AND
  pattern-position literals AND variable mutators AND better
  attribute classification. v2 work.
- **Upstream Elixir heredoc fix revert**. Tracking note + TODO
  comment, not a milestone. Single PR when upstream lands.

# Out of scope for v1.10 (do not let it sneak in)

- New mutators (body-literal table TUNING is in scope; new mutator types are not).
- Schema-routing migration code (decision in M25; code is v1.11+).
- New CLI flags (M22's `--test-timeout-ms` is the last one for the v1.X line).
- Cross-run state persistence (v2).
- Wrapper guard schemata (v2 if metrics ever justify; v1.8 confirmed they don't).
- Pattern-position mutators (v2 with env walker).
- Variable mutators (v2 with env walker).
- Coverage caching (v2).
- Mutation semantics changes.
- Stable_id input changes (a future schema-routing migration would be a separate, explicit migration milestone).
- Per-test-case coverage attribution (v2).
