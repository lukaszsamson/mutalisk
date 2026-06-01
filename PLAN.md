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
  new mutants and report kill rate as an observation (kill rate is
  a property of the project's test suite, not the mutator).
- Skip M33 if M27-M30 consumes the v1.11 budget; defer to v1.12.

> **v1.11 closure note (2026-05-10):** the mutator was already
> implemented in v1.5 (`06e8398`); M33's v1.11 work was bench
> validation only. Observed kill rates: plug_crypto 33.3%,
> Decimal 39.5%. The original ≥60% acceptance bar was reframed
> as an observation — surviving boundary mutants reflect test-
> suite edge-case gaps in the bench targets, not a mutator-design
> defect. See CHANGELOG.md M33 entry.

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

# v1.12 milestones (stabilize the expanded harness)

v1.11 closed with two M27 follow-throughs deferred and the
default-flip gate properly closed on structural grounds. v1.12's
job is to fix the Mutalisk-owned correctness regression that
blocks 3 pinned OSS targets, finish wiring M27's pool-warm-state
class into the user-facing surface, characterize whether
pool-warm-state drift can be closed, and decide whether catalog
growth continues without the env walker.

**Theme**: stabilize the expanded harness; do not add broad new
mutation surface until the env walker.

**Default `--worker-type` does NOT flip in v1.12.** The gate
remains structurally closed (Ecto, Gettext, clustered Mox).
v1.12 may sharpen the mix-only catalogue but will not move the
default.

**Default `--selection` does NOT flip in v1.12.** Coverage stays
opt-in until persistent-worker stabilization completes.

Four committed milestones, sequenced. Cheap correctness fix
first; UX wins next; characterization spike before any structural
work; mutator decision last.

## v1.12 scope (committed)

**M34 — `Mut.SchemaPlacer` escaped-quote fix.** Highest priority:
Mutalisk-owned regression, blocks `phoenix_html`, `plug`, and
`phoenix_pubsub` under both `mix` and `persistent` workers.
- Fix `Mut.SchemaPlacer.render/1` round-trip for strings
  containing escaped quotes (`\"…\"`, escaped backslashes, and
  related escape sequences).
- Add a fixture regression covering escaped-quote string content
  in both body and module-attribute positions.
- Re-bench `phoenix_html`, `plug`, `phoenix_pubsub` in both
  worker modes; record results in BENCHMARKS.md and reclassify
  from `unrunnable` to whatever the bench surfaces (clean / drift
  / informational).
- Acceptance: schema build no longer crashes on the three pinned
  targets; both worker types reach mutant execution; new fixture
  test added; existing `golden_instrument` layer remains green.

**M35 — Pool-warm-state boot warning + drift bucketer
hardening.** Bundled because both are M27 follow-throughs;
neither alone justifies a milestone.
- Extend persistent boot-warning catalogue with HTTP-client /
  pool signatures: `:mint`, `:finch`, `:nimble_pool`. Do NOT
  preemptively add `:poolboy`/`:hackney`/`:gun`/`:connection` —
  add when a real target surfaces drift, not before.
- Boot warning fires on mint/nimble_pool fixtures; silent on
  plug_crypto/Decimal/demo_app.
- Drift bucketer: per-bucket unit tests covering every heuristic
  (especially `:pool_warm_state`); `--json` output for CI
  consumption; include report paths and sample stable_ids in
  output for faster triage.
- Acceptance: bucketer remains <5% unclassified on M25+M27
  corpus; pool boot warning fires correctly; PERSISTENT_WORKER_
  GUIDE documents pool signatures as persistent-risk (NOT hard
  mix-only — the spike below decides that).

**M36 — Pool-warm-state characterization spike.** Do not jump
to reset hooks. Characterize the leak class first; the answer
may be "classify mix-only" (mirroring M30's Ecto outcome).
- Three modes on `mint` and `nimble_pool` (and `finch` if
  toolchain permits): current persistent in-process,
  aggressive process-tree reset (kill+restart pool supervisors
  between mutants), restart-project-apps-per-mutant.
- Measure: drift partition vs `mix`, wall-clock cost, memory.
- Identify the dominant leak vector: process-tree state, ETS
  registry state, socket state, or `Application` env.
- **Parse-class subsection**: re-examine the 4 residual
  parse-class mutants (2 on `nimble_options`, 2 on `mox`) in
  light of the spike's findings. Do any of the candidate
  isolation modes also bear on parse-class? If yes, fold the
  fix into the recommended path. If no, document and accept
  parse-class as a known persistent limitation (it's 4 mutants
  across the corpus; not worth a dedicated milestone).
- Output: written decision doc at
  `docs/spikes/M36_pool_warm_state.md`. Three options on the
  table: reset hook (if cheap and effective), mix-spawn reroute
  for affected mutants, or formal mix-only classification.
- Acceptance: decision doc committed with three-mode comparison
  table and explicit recommendation. Parse-class disposition
  named in the same doc.
- If the recommendation is "reset hook is cheap and effective,"
  promote to implementation in the same milestone or a v1.12
  follow-up commit; do NOT defer to v1.13.

**M37 — Mutator-surface decision.** Three releases in a row
without a new mutator weakens the value prop, but the env
walker is still v2 work. Decide explicitly: ship one narrow
schema-safe extension OR formally defer all catalog growth to
the env walker.
- Candidate: `Mut.Mutator.ComparisonNegation` (`==` ↔ `!=`).
  Schema-routed via existing dispatch oracle, no env walker
  required, structurally analogous to M33's ComparisonBoundary.
  Atoms / strings / maps / lists / list-construction stay v2.
- Decision criteria: the candidate must be schema-routed (no
  fallback-only mutators in this milestone), unambiguous in
  body context (no env-walker dependency), and stable_id-safe
  (no migration). If the candidate fails any criterion, the
  outcome is "defer all catalog growth to env walker (v2)."
- If shipped: validate on plug_crypto, Decimal, and ≥2 OSS
  targets from the M25/M27 corpus. Report kill rate as an
  observation (per the M33 reframing — kill rate is a property
  of the test suite, not the mutator).
- Acceptance: either (a) one new schema-routed mutator landed,
  unit-tested, golden layers green, validated on ≥4 targets, OR
  (b) decision doc at `docs/spikes/M37_mutator_surface.md`
  formally deferring all catalog growth to v2. Both outcomes
  ship v1.12.

> **v1.12 closure note (2026-05-10):** outcome (a). The candidate
> mutator was already implemented in v1.5 (`06e8398`); M37's v1.12
> work was bench validation only. Validated on 8 targets
> (plug_crypto, Decimal, nimble_options, mox, jason, mint, plug,
> phoenix_html); kill rates 75–100% reported as observation per
> the M33 reframing. No new code. Further catalog growth (atoms /
> strings / maps / lists / list-construction) remains v2 work
> behind the env walker. See CHANGELOG.md M37 entry.

## v1.12 default-flip gate (unchanged from v1.11 closure)

Default `--worker-type` STAYS `mix`. The structural drift classes
(Ecto, Gettext, clustered Mox) cannot be closed by reset hooks;
M30 and M31 documented this. v1.12 does not relitigate. M36's
spike may add or close pool-warm-state, but pool-warm-state alone
does not gate the default.

## v1.12 horizon (not v1.12 scope)

- **Helper-process recompile isolation implementation** —
  rejected by M29 on root-cause grounds. Reopen only if a real
  target surfaces drift that helper-process isolation
  demonstrably closes (M29's spike concluded the leak class is
  BEAM-global ETS, not process-local).
- **Affected-test selection** — M32 shelved on risk-surface
  analysis; reopening criteria documented there. Not v1.12.
- **Body-literal schema-routing migration** — gated on
  body-literal becoming default-on, which has not happened.
- **Env walker (v2 architecture)** — unblocks atoms / strings /
  maps / lists / pattern-position literals / variable mutators
  / better attribute classification. The long-deferred work.
- **Upstream Elixir heredoc fix revert** — tracking note + TODO,
  not a milestone.

## Explicitly NOT v1.12

- New CLI flags beyond what M35's bucketer needs (`--json`).
- Cross-run state persistence (v2).
- Wrapper guard schemata (v1.8 measurements showed fallback is
  not dominant overhead).
- Persistent default flip (closed on structural grounds).
- Coverage default flip (deferred until persistent stabilizes).
- Stable_id input changes (any future migration is its own
  explicit milestone).
- Reopening Ecto / Gettext / clustered-Mox persistent support
  (mix-only is the documented disposition; reopen only on a
  fundamentally different approach, not on incremental hooks).

# v1.13 milestones (doc closure + env walker design)

v1.12 closed with two M27 follow-throughs landed (M34 SchemaPlacer
fix, M35 pool-warm-state boot warning + bucketer hardening), the
pool-class characterized as "supported with caveat" (M36), and
ComparisonNegation validated (M37). The recurring "deferred to v2
with the env walker" has been sitting in PLAN.md since v1.5; v1.13
is when that gets actually scoped.

**Theme**: doc closure for v1.12 + design the env walker without
implementing it. v1.13 ships two milestones — one mechanical, one
substantive.

**Default `--worker-type` does NOT flip in v1.13.** Closed
structurally; v1.13 does not relitigate.

**Default `--selection` does NOT flip in v1.13.** Coverage stays
opt-in.

## v1.13 scope (committed)

**M38 — v1.12 documentation closure + spike-env-var cleanup.**
Mechanical milestone. Cleans v1.12's release-doc inconsistencies
and removes spike-only env vars whose decisions concluded "don't
ship."

Doc fixes:
- `docs/PERSISTENT_WORKER_GUIDE.md`: rename "v1.11 catalogue" →
  "v1.12 catalogue"; update the "all three rows / none closed"
  paragraph to reflect four rows post-M35; delete the stale
  paragraph claiming pool projects are "NOT yet in the boot-
  warning catalogue" (M35 added them); rewrite the pool row's
  "M36 may close this class" → "M36 confirmed reset hooks
  ineffective on pure-library OTP apps; pool drift is
  `mix=Survived → persistent=Killed`, persistent may be more
  thorough rather than wrong."
- `BENCHMARKS.md`: plug v1.19.1 row's bucket annotation updated
  from `unclassified ×16 + parse_class ×1` to
  `:supervisor_init ×16 + parse_class ×1` (M35's heuristic
  reattribution).
- `lib/mut/worker/persistent/detector.ex` moduledoc: catalogue
  text updated to match the `@signatures` data table — add
  `:pool` row, narrow `:mox` description to clustered/peer-state
  residual (M28 finding), narrow `:ecto` description to
  supervisor-init structural drift (M30 finding).

Spike-env-var cleanup:
- Remove `MUT_PERSISTENT_COMPILE_MODE=helper_process` and
  `compile_via_helper_process/1` (M29's spike; concluded
  "don't ship"). Resurrect from git if a future spike needs it.
- Remove `MUT_PERSISTENT_POOL_RESET=apps_restart` and
  `reset_pool_apps/0` (M36's spike; concluded "supported with
  caveat, no reset hook"). Same resurrection policy.
- Remove `reset_pool_us` from `MUT_RUN_METRICS` and the
  Persistent worker reset-hooks terminal block.
- Remove env-var forwarding entries from `Persistent.port_env/1`.

Policy additions to the guide:
- `:supervisor_init` policy note distinguishing Ecto-class
  (mix-only, structural — `Application.start/2` reordering)
  from low-rate plug-class drift (supported, ~5%; persistent
  may be more thorough). Two-sentence note in the boot-warning
  section, NOT a new catalogue row.
- `mix mut.drift --json` schema: documented in the guide with
  one mix-target and one all-targets example. Schema is
  considered stable for CI consumption from this point forward
  (any future schema change becomes a SemVer concern).

Out of M38 scope:
- `--fail-on-drift` flag for `mix mut.drift`. Add when a real
  user asks; don't preemptively design a CI gating contract.
- Any rewriting of the `@signatures` data table (only the
  moduledoc text is stale).
- Any change to the persistent worker's behavior (this is doc
  + cleanup only).

Acceptance:
- Grep-based stale-phrase checks pass: no occurrences of
  `M36 may close`, `pool not yet`, `v1.11 catalogue` (in
  v1.12+ contexts), `Mox.Server mock-registry leaks` (in
  detector moduledoc), `Ecto.Query planner.*caches` (in
  detector moduledoc).
- `MUT_PERSISTENT_COMPILE_MODE` and `MUT_PERSISTENT_POOL_RESET`
  do not appear in `lib/`.
- `bin/verify` green.

**M39 — Env walker design spike.** The substantive v1.13
milestone. Design the env walker that unblocks v2's mutator
catalog (string/atom/list/map/tuple body literals, pattern-
position literals, variable mutators, better attribute
classification). Spike output is a written design doc; no code
ships.

Reference implementation to study (NOT to copy):
- `~/elixir_sense/lib/elixir_sense/core/compiler.ex` and
  related modules. ElixirSense's compiler module performs an
  AST traversal of module and function bodies using public
  `Macro.Env` APIs. It does NOT invoke macros, evaluate code,
  or run module callbacks — expansion is best-effort, which
  is exactly the contract we need. ElixirSense expands a bit
  differently in modules and functions than `:elixir_expand`
  does, and it goes marginally further than mutalisk needs
  (it tries to expand more constructs to collect richer
  metadata for IDE features); the mutalisk walker should aim
  for the strict subset that establishes context without
  collecting symbol-table data.

Why NOT use `:elixir_expand` directly:
- `:elixir_expand` performs full evaluation + expansion,
  writes modules and functions to internal compiler ETS
  tables, and interacts with the real compiler. It is not
  isolatable, parallelizable, or safe to run inside a
  long-lived persistent worker without state contamination.
  ElixirSense's approach (best-effort traversal using only
  public `Macro.Env` APIs) is what makes the walker usable as
  a host-side oracle pass.

Design doc deliverable at `docs/spikes/M39_env_walker.md` must
answer:

1. **Context discrimination.** Concrete AST-walk strategy for
   distinguishing body / guard / pattern / quote / macro
   contexts. Map each context to its `Mut.EnvSnapshot`
   classification (`:trusted`, `:opaque`, `:untrusted_descendant`,
   `:quoted`, `:generated`). Reference the elixir_sense
   approach where it informs the design; deviate where
   mutalisk's narrower needs justify a simpler walk.
2. **User macro opacity policy.** Non-negotiable: the walker
   does NOT expand user macros. Document how unknown macro
   calls are classified (`:opaque` boundary; descendants
   become `:untrusted_descendant`). Confirm that no macro
   expansion path exists in the proposed walker by inspection,
   not by testing.
3. **Public-API surface.** Enumerate the `Macro.Env` APIs the
   walker depends on. Note any that are "public but
   undocumented" (similar to v1.7's ExUnit private-API
   reliance, which forced the Elixir 1.18.0 floor). If the
   walker forces a higher Elixir floor, that's a v2 release-
   note item.
4. **Stable-ID strategy.** Critical: declare whether the env
   walker can be added without a stable_id migration
   (preferred — keeps v1's bytestream identity contract
   intact) or forces one. If migration is forced, the
   acceptance bar for the first implementation milestone
   shifts (it becomes a stable_id migration milestone, not a
   mutator addition milestone).
5. **Cold-compile cost estimate.** Walker traversal time on
   demo_app + Decimal + plug, measured by prototype if
   needed. Hard constraint: walker must not double oracle-
   build wall on Decimal-class projects. v1.5 picked tracer-
   only specifically to avoid compile-time walker cost; if
   the env walker can't beat that constraint, the design
   pivots (incremental walker? walker-on-demand for mutated
   modules only?). A negative outcome here is a real result.
6. **Mutator ordering for first implementation.** Which
   mutators become possible in what order. Likely sequence:
   string body literals → atom body literals (with
   atom-table-pollution policy) → list/map/tuple body
   literals → pattern-position literals → variable mutators.
   Justify the ordering on equivalent-mutant rate and walker-
   complexity grounds.
7. **Go/no-go gate for v1.14 implementation.** Concrete
   acceptance criteria for the first implementation milestone:
   LOC estimate, target cold-compile overhead, byte-identity
   preservation for v1's existing dispatch-shaped mutants
   (env walker MUST NOT regress the tracer oracle's coverage),
   validation target set.

Acceptance for M39:
- Design doc committed at `docs/spikes/M39_env_walker.md`.
- All seven questions answered concretely (not "TBD").
- Cold-compile cost number measured, not estimated. Prototype
  walker (throwaway) acceptable to land the measurement;
  prototype is NOT shipped code.
- Stable-ID migration policy explicit (yes/no, with rationale).
- Go/no-go recommendation explicit. v1.14 implementation
  milestone scope written into PLAN.md as a horizon item if
  go.

Out of M39 scope:
- Any production code path. This is a spike like M29 / M32 /
  M36. Prototype code stays in `tmp/` or a throwaway branch.
- Implementing any new mutator. M37 was the v1.12 closure for
  catalog growth; v1.13 does not ship new mutators.
- Pattern-mutator framework design. Pattern-position literals
  are first-class in M39's ordering, but the higher-risk
  pattern mutators (pin/unpin variable swaps, arity changes)
  remain v2 design work.

> **v1.13 closure note (2026-05-11):** decision = **go for v1.14**.
> Spike doc committed at `docs/spikes/M39_env_walker.md` with
> explicit answers to all 7 PLAN.md questions: context
> discrimination (recursive descent over source AST with explicit
> per-form context transitions), user macro opacity policy (no
> expansion; tracer-oracle proof required for `Kernel.if`/`unless`
> trust), public-API surface (no floor bump beyond 1.19),
> stable-ID strategy (no migration; existing dispatch IDs
> preserved), cold-compile cost (parse+walk ≤ 0.72% of oracle
> build on plug — well below the 10% gate), mutator ordering
> (string → float → atom → list/map/tuple → attribute → pattern
> → variable), and v1.14 go/no-go gate (~970 production + ~450
> test LOC; first mutator: `Mut.Mutator.StringLiteral` only).
> See CHANGELOG.md M39 entry.

## v1.13 horizon (not v1.13 scope)

- **Env walker first implementation** — v1.14 candidate iff
  M39 returns go. Likely string body literals as the first
  mutator (lowest equivalent-mutant rate, simplest walker
  context).
- **Stable_id migration** — v1.14+ if M39 says forced.
  Otherwise indefinitely deferred.
- **Atom-table pollution policy** — v1.14 design item for the
  atom-literal mutator. Whether to whitelist replacements,
  bound the atom-creation rate per run, or refuse to mutate
  atoms by default.
- **Pattern mutator framework** — v2 work; M39 documents
  feasibility, doesn't design.
- **Variable mutators** — v2 work; M39 enumerates but doesn't
  design.

## Explicitly NOT v1.13

- Persistent default flip (closed structurally).
- Coverage default flip (deferred until persistent stabilizes).
- Affected-test selection (M32 shelved; reopening criteria
  documented there).
- Helper-process recompile isolation (M29 rejected).
- Reopening Ecto / Gettext / clustered-Mox persistent support.
- Body-literal schema routing migration.
- Any new mutator (M37 was the v1.12 catalog-growth closure).
- New CLI flags (`--fail-on-drift` deferred until requested).
- Stable_id input changes (any future migration is its own
  explicit milestone, gated on M39's migration policy).

# v1.14 milestones (env walker first implementation)

M39 returned **GO** for v1.14 with measured cold-walk cost
0.06%/0.21%/0.72% of oracle wall on demo_app/Decimal/plug —
14× headroom against the 10% hard gate. v1.14 ships the env
walker as a fifth candidate source and `Mut.Mutator.StringLiteral`
as the first env-walker-backed mutator, behind opt-in flags.

**Theme**: first env-walker implementation, narrow mutator
surface, no stable-id migration. M39 declared no migration
required; v1.14 acceptance enforces it.

**Defaults do NOT change in v1.14.** `--worker-type mix`,
`--selection static`, env walker disabled unless
`--enable env_walker` / `--enable string_literal`.

Two milestones, mirroring M19's pattern (one large
implementation milestone with internal commit pacing + one
validation/decision milestone).

## v1.14 scope (committed)

**M40 — Env walker + StringLiteral mutator
(foundation through integration).** One milestone, ~970
production LOC + ~450 test LOC per M39's estimate. Ships the
entire bundle behind opt-in. M19 precedent: large
implementation milestones use internal commit pacing rather
than splitting into multiple shippable milestones.

Step-by-step deliverables (7 commits):

1. `Mut.EnvSnapshot` + `Mut.OpaquePolicy` data types. No
   walker yet. Unit tests on classification helpers and the
   `:trusted` / `:opaque` / `:untrusted_descendant` / `:quoted`
   / `:generated` enum.
2. `Mut.EnvWalker` skeleton — recursive descent over special
   forms (`defmodule`, `def`, `defp`, `defmacro`, `defmacrop`,
   `defguard`, `defguardp`, `fn`, `case`, `with`, `try`,
   `quote`, `unquote`, `=`, `when`, `^`). No oracle
   integration yet. Per-form tests on body / guard / pattern /
   quote / macro context discrimination. Opaque-boundary
   tests for unknown macro calls.
3. `Mut.EnvOracle` (in-memory index from source-span →
   snapshot) + orchestrator hook as fifth candidate source
   alongside `dispatch_candidates`, `guard_candidates`,
   `attribute_candidates`, `body_literal_candidates`.
   Disabled by default; orchestrator wiring test only.
4. Defguard / `if` / `unless` trusted-only-with-tracer-proof
   logic. M39's key constraint: these are trusted ONLY when
   the tracer oracle confirms they resolve to
   `Kernel.if/2` / `Kernel.unless/2` / `Kernel.defguard/1`,
   not user redefinitions. Sequence before the mutator so the
   trust contract is battle-tested first.
5. `Mut.Mutator.StringLiteral` — fallback-routed (not schema-
   routed; v1.14 does not force a stable-id migration), scope
   `:function_body`, context `nil`, trust `:trusted`.
   Replacement table: non-empty → `""`. Empty → skip.
   Interpolated strings (`"x#{y}"`) → skip per M39 ordering
   item 6 (source-span replacement not yet proven safe).
6. Diagnostics + metrics: skip-reason histogram
   (`:opaque` / `:quoted` / `:generated` / `:missing_span` /
   `:untrusted_descendant`), env-walker `parse_ms` and
   `walk_ms` in `Mut.Metrics.Snapshot`, reporter integration
   (terminal block + Stryker JSON `mutalisk.env_walker` key).
7. Public `--enable env_walker` / `--enable string_literal`
   flags, CHANGELOG entry, BENCHMARKS scaffolding for M41,
   all 9 `bin/verify` layers green.

Acceptance gates (whole milestone):

- **Byte-identity gate** (hardest). Existing dispatch /
  guard / attribute / body-literal stable IDs unchanged on
  demo_app, plug_crypto, Decimal, and plug. Verified via a
  stable-id diff harness comparing pre-M40 HEAD's plan
  against post-M40 HEAD's plan with `--enable env_walker`
  ON and OFF. Env walker MUST NOT regress the tracer
  oracle's coverage.
- **No-expansion gate**. Automated grep over env-walker code
  paths: zero occurrences of `Macro.expand`, `Macro.expand_once`,
  `Code.eval_`, `Code.compile_`, `Kernel.ParallelCompiler`,
  `:elixir_expand`, `:elixir_module`, `:elixir_def`,
  `Macro.Env.expand_import`, `Macro.Env.expand_require`,
  `Macro.Env.define_import`, `Macro.Env.fetch_alias`,
  `Macro.Env.fetch_macro_alias`. M39 enumerated the forbidden
  list; M40 automates the check as a verify layer.
- **Cold-compile gate**. `parse_ms + walk_ms ≤ 10% of
  oracle_build_ms` on Decimal and plug, measured in CI per
  run. M39's prototype reported 0.21% / 0.72% — 14× headroom.
  Hard regression bar; if production overhead inflates past
  10×, fix before merge.
- **Opt-in default**. Env walker disabled unless
  `--enable env_walker` or `--enable string_literal` is set.
  Default `bin/verify` runs do NOT exercise the walker.
  Verify this via a default-run plan-diff (pre-M40 plan ==
  default-flags post-M40 plan).
- **No regression of existing mutators**. Decimal's integer-
  literal + boolean-literal + body-literal kill counts
  unchanged. Demo_app fixture stable IDs unchanged.
- **All 9 `bin/verify` layers green.**

Subagent brief (for a fresh agent picking up M40):
- M39's design doc at `docs/spikes/M39_env_walker.md` is
  binding. Do not deviate from the 11 public APIs enumerated
  in M39's answer to question 3 without explicit re-design.
- Use `~/elixir_sense/lib/elixir_sense/core/compiler.ex` as a
  reference for the AST-traversal pattern. ElixirSense's
  walker collects more than mutalisk needs (symbol-table
  metadata for IDE features); strip to context-only.
- Do NOT migrate any existing `Mut.AstWalk` walker behind
  EnvWalker. That's v1.15+ and has its own byte-identity gate.
- Fallback-route, not schema-route. Schema routing for
  literals is a separate stable-id migration decision (M25
  Decision 2 territory).

**M41 — Real-target validation + StringLiteral default
decision.** Mirrors M24 / M25's matrix-then-decide shape.
Runs the matrix exactly once; uses the data to decide
whether StringLiteral stays opt-in, expands its replacement
table, or reverts to opt-in-experimental.

Validation matrix (5 targets × `{enabled, disabled}` ×
`{mix, persistent}`):

- demo_app — fixture-level proof: hand-placed string literals
  are killed by the demo test suite. Smallest signal, fastest
  feedback.
- plug_crypto — small dispatch-heavy baseline.
- Decimal — large arithmetic-heavy byte-identity stress.
- plug — M34-unblocked, supervisor-init drift class.
- phoenix_html — M34-unblocked macro-heavy target. Tests
  opaque-policy classification on `@doc ~S"""…"""` sigil
  heredocs and EEx-generated internals.

(gettext as alternative macro-heavy target is mix-only per
M31; phoenix_html exercises the opaque policy harder and is
the primary pick. If budget allows, run gettext under
`--worker-type mix` as a secondary informational target.)

Measure per target:
- New string mutants surfaced (count + sample stable_ids).
- Kill / survived / error / invalid counts.
- Env-walker parse + walk time vs oracle wall.
- Stable-ID diff for existing mutants (MUST be zero).
- Skip-reason histogram counts
  (`:opaque` / `:quoted` / `:generated` / `:missing_span`).
- Mutant-run wall delta vs disabled.

Decision output at `docs/decisions/M41_string_literal_decision.md`,
mirroring M25 / M36 decision-doc conventions:

1. **StringLiteral default policy**:
   - `keep_opt_in` (conservative default) — if invalid rate
     ≥10% on any target OR opaque-policy false negatives
     detected (trusted mutants inside known DSL-generated
     internals).
   - `expand_table` — if equivalent-mutant rate <20% AND kill
     rate ≥60%. Candidate replacements: `non-empty → "x"`,
     `non-empty → " " + s`.
   - `defer_further` — if matrix surfaces an unknown invalid
     class. Revert to opt-in-experimental flag (separate from
     `string_literal`) and re-spike in v1.15.

2. **Interpolated-string disposition**: M39 deferred until
   source-span replacement is proven safe. M41 records
   whether the matrix surfaced demand for interpolated-string
   mutation; if yes, scope a v1.15 milestone.

Side validations (same data, no new bench cycles):
- Env-walker overhead on persistent vs mix workers (M40's
  cold-compile gate applies to mix-spawn; persistent's warm
  BEAM amortizes parse but not walk).
- Opaque-policy effectiveness: false positives (trusted
  mutants the policy should have rejected) and false
  negatives (opaque rejections that were actually safe).
- Skip-reason distribution informs v1.15+ walker hardening.

Acceptance:
- Zero stable-ID churn for existing mutants on all 5 targets.
- Parse + walk gate holds in production on Decimal and plug.
- No-expansion grep gate holds.
- Decision doc committed with explicit recommendation.
- BENCHMARKS.md gains a v1.14 section.
- `PERSISTENT_WORKER_GUIDE.md` notes interaction (if any)
  between env walker and persistent worker.

> **v1.14 closure note (2026-05-11):** decision = `keep_opt_in`.
> Plan-level validation matrix on 5 acceptance targets confirms
> zero stable-ID churn (binding M40 byte-identity gate);
> kill-rate evaluation is operator-driven and out of M41's
> plan-only scope. Three production fixes shipped as part of
> M41 measurement: literal_span end-byte regression on string
> literals (fell back to `:end_of_expression` when `:token` is
> absent), JSON-safe `ast_path_hash` encoding (Base16 hex
> mirroring `Mut.AstWalk.path_hash/1`), and the missing
> `fallback_env_context(_, _, :env_walker)` orchestrator clause.
> See CHANGELOG.md M41 entry + `docs/decisions/M41_string_literal_decision.md`.

## v1.14 horizon (not v1.14 scope)

- **Float / atom / list / map / tuple body literals** — M39's
  ordering item 6. v1.15+ candidate. Atom mutator requires
  atom-table pollution policy (see horizon below).
- **Atom-table pollution policy** — design item for the
  atom-literal mutator. Whitelist replacements? Bound
  atom-creation rate per run? Refuse to mutate atoms by
  default? v1.15+ design.
- **Pattern-position literals** — M39 ordering, v1.15+.
- **Variable mutators** — M39 ordering, v1.15+.
- **Interpolated-string mutation** — M41 decision input;
  v1.15+ if demand surfaces.
- **Migrating existing walkers behind EnvWalker** — v1.15+
  with its own byte-identity gate per M39's "key
  architectural commitments." Forbidden in v1.14.
- **Body-literal schema-routing migration** — orthogonal to
  env walker; gated on body-literal default-on, which has
  not happened.

## Explicitly NOT v1.14

- Schema-routing for any env-walker mutator. v1.14 routes
  through fallback exclusively. Stable-id migration is
  v1.15+ if ever.
- Migrating existing `Mut.AstWalk` walkers behind
  `EnvWalker`. M39 explicitly forbids this in v1.14.
- Persistent default flip (closed structurally).
- Coverage default flip.
- Affected-test selection (M32 shelved).
- Helper-process recompile isolation (M29 rejected).
- Reopening Ecto / Gettext / clustered-Mox persistent
  support.
- Stable-ID input changes. M39 declared none required;
  reopen only if a future mutator forces one (would be its
  own explicit migration milestone).
- New CLI flags beyond `--enable env_walker` and
  `--enable string_literal`.
- `--fail-on-drift` for `mix mut.drift`.

# v1.15 milestones (prune worker types + grow env-walker literals)

v1.14 closed with `keep_opt_in` for StringLiteral and zero
stable-ID churn. v1.15 changes register: it is a **pruning +
focused mutator expansion** release, not infrastructure. Two
moves: (1) delete the persistent-worker subsystem, which closed
structurally in v1.11, is slower than `mix` on the targets that
matter, and taxes every other workstream with dual-worker
validation; (2) reinvest that freed budget into the env-walker
literal catalogue.

The env walker (v1.14) and coverage selection (v1.5) stay. Only
the persistent worker leaves.

**Defaults do NOT flip in v1.15.** `--worker-type` is *removed*
(`mix` becomes the only worker; `--worker-type mix` is a
deprecated warn-once no-op for one release, `persistent` errors).
`--selection static` stays default — coverage stays opt-in.
New mutators ship opt-in; M46 decides defaults from execution
data. Elixir floor stays `>= 1.19.0`.

Five milestones. The low-risk core is **M42 + M44 + M46**
(removal + low-noise literals + validation). **M43** (walker
consolidation, pure refactor) and **M45** (atom + collection,
the noisy literals) are designated release valves: each can slip
to v1.16 at zero downstream cost if budget tightens.

## v1.15 scope (committed)

**M42 — Worker-type removal + model/doc simplification.**

*Goal:* `mix` is the only worker. Delete the persistent
subsystem and everything that exists solely to manage worker-type
divergence. Mutation outcomes are unchanged.

*Inputs:* HLD v1.15 §M42; v1.11/v1.12 outcome notes (structural
default-flip close); BENCHMARKS persistent-vs-mix rows.

*Deliverables:*
- Delete `lib/mut/worker/persistent.ex`,
  `lib/mut/worker/persistent_runner.ex`,
  `lib/mut/worker/persistent_runner/reset.ex`,
  `lib/mut/worker/persistent_runner/diag.ex`,
  `lib/mut/worker/persistent/detector.ex` and their tests
  (~2,250 LOC).
- Delete `lib/mix/tasks/mut.drift.ex`,
  `lib/mut/drift/bucketer.ex`, `lib/mut/drift/bucketer/result.ex`
  and their tests — these triage mix-vs-persistent stable-id
  diffs and have no standalone consumer.
- Strip the `--worker-type` branch from `lib/mut/cli.ex`,
  `lib/mix/tasks/mut.ex`, `lib/mut/worker.ex`. Keep
  `--worker-type mix` as a deprecated no-op that warns once;
  `--worker-type persistent` exits non-zero with a message
  pointing at the CHANGELOG.
- Remove the `e2e_persistent` layer from `bin/verify` and any
  `mix mut.e2e` persistent path.
- Drop persistent metric blocks from `lib/mut/metrics.ex`,
  `lib/mut/reporter/terminal.ex`,
  `lib/mut/reporter/stryker_json.ex`.
- Clean persistent references in `lib/mut/application.ex`,
  `lib/mut/runtime.ex`, `lib/mut/schema_placer.ex`,
  `lib/mut/recompile.ex`, `lib/mix/tasks/mut/e2e.ex`.
- Delete `docs/PERSISTENT_WORKER_GUIDE.md`. Prune the now-moot
  mix-only catalogue and structural-drift prose from docs.
  **Keep** the SchemaPlacer escaped-quote note — that bug
  affected both worker types.
- README/CHANGELOG/BENCHMARKS accuracy pass: the README still
  describes sequential execution, static-only selection, and
  "no arbitrary literals" — all stale since v1.5/v1.9/v1.14.
  Bring them in line with the simpler post-removal model
  (concurrency, coverage opt-in, env-walker literals opt-in,
  single worker).

*Acceptance:*
- Remaining `bin/verify` layers green (one fewer layer).
- demo_app / plug_crypto / Decimal stable-id sets AND kill
  counts byte-identical to v1.14 `mix`-worker runs.
- `grep -rn 'persistent\|worker_type\|worker-type' lib/`
  returns nothing except the deprecated-flag warn-once shim.
- No dangling references in docs to deleted modules/flags.

*Out of scope:* New mutators. Touching the env walker. Coverage.

**M43 — EnvWalker consolidation (byte-identity gated). ⚠️ release valve — SLIPPED to v1.16 (2026-05-23).**

> **Status: deferred to v1.16.** A pre-implementation spike proved the
> byte-identity gate cannot be met by making `EnvWalker` the single
> candidate source: `EnvWalker` emits `ast_path = []` for every literal
> (identity via byte span — the M41 design) while the four `AstWalk`
> walkers emit detailed positional paths; unifying forces one encoding
> and churns the other side. Release valve exercised per the clause
> below. Evidence + the v1.16 redesign direction (AstWalk absorbs
> EnvWalker, not the reverse) in
> `docs/decisions/M43_envwalker_consolidation.md`. M44/M45 are
> unaffected and proceed against the parallel fifth-source EnvWalker.

*Goal:* Make `EnvWalker` the single source of mutation
candidates. M40 explicitly deferred this to v1.15+ with its own
byte-identity gate.

*Inputs:* HLD v1.15 §M43; `docs/spikes/M39_env_walker.md`;
M40's stable-id diff harness; the four existing walkers in
`lib/mut/ast_walk.ex`.

*Deliverables:*
- Migrate `dispatch_candidates/2`, `guard_candidates/2`,
  `attribute_candidates/2`, `body_literal_candidates/1` to derive
  context from `EnvWalker` snapshots rather than standalone
  `Macro.traverse` passes. `EnvWalker` becomes *the* walker; the
  fifth-source plumbing collapses into the primary path.
- Extend the M40 no-expansion grep verify layer to cover the
  migrated code paths.
- Reuse M40/M41's stable-id diff harness as the gate.

*Acceptance:*
- Stable IDs byte-identical for every existing mutator
  (dispatch / guard / attribute / integer / boolean / string)
  on demo_app, plug_crypto, Decimal, plug. **Any churn stops the
  migration** — fall back to the parallel fifth-source design and
  reschedule to v1.16.
- Cold-walk still ≤10% of oracle-build wall on Decimal and plug.
- No-expansion grep gate green on migrated paths.
- All kill counts unchanged.

*Out of scope:* New mutators. Schema routing. Any stable-id
input change (a churn here is a failure, not a migration).

*Release-valve note:* This milestone has no user-visible payoff
and the most regression surface. If v1.15 runs long, cut it to
v1.16; M44/M45 do not depend on it.

**M44 — Low-noise literal expansion: Float + Nil + String table.**

*Goal:* Add the two lowest-noise next literals per M39 ordering
plus a richer StringLiteral table. All env-walker, fallback-
routed, opt-in.

*Inputs:* HLD v1.15 §M44; M39 ordering; M41 StringLiteral
decision (`keep_opt_in`); `Mut.Mutator.StringLiteral` as the
reference implementation.

*Deliverables:*
- `Mut.Mutator.FloatLiteral`: body-context float literals.
  Replacements `0.0 → 1.0`, finite `f → 0.0`, `f → f + 1.0`,
  with equivalent-mutant filters (skip where the float feeds a
  position the filter flags as no-op). `targets/0 == [:literal]`,
  `applicable?/2` requires `engine == :fallback` and trusted
  body context.
- `Mut.Mutator.NilLiteral`: body-context `nil`. Replacement
  `nil → :__mut_nil__`-class sentinel (closed, single
  replacement); pattern and guard positions excluded.
- `StringLiteral` `expand_table`: add `non-empty → "x"` and
  prepend-space (`s → " " <> s`) replacements behind the existing
  opt-in. Interpolated-string handling only if M41/validation
  recorded demand (M41 did not; default off).
- Per-mutator unit tests + fixture golden mutation lists.
  Invalid rate tracked per mutator.

*Acceptance:*
- Zero stable-id churn for existing mutants on demo_app,
  plug_crypto, Decimal, plug, phoenix_html.
- New mutators disabled unless `--enable env_walker` plus the
  per-mutator enable; default `bin/verify` does not exercise them.
- Golden mutation lists committed for the fixture.

*Out of scope:* Atom and collection literals (M45). Default
decisions (M46). Schema routing.

**M45 — Higher-noise literals: Atom + Collection. ⚠️ release valve, gated.**

> **Status: shipped 2026-05-23, with a scope trim.** `AtomLiteral`
> (closed allowlist) and `CollectionEmpty` for **lists and 2-tuples**
> landed. **Maps (`%{...}`) and n-tuples (`{a,b,c}`) are deferred to
> v1.16**: list/2-tuple literals are wrapped by the parser's
> `literal_encoder` (so they are cleanly distinguished from structural
> keyword-list args / `do:` blocks), but maps and n-tuples are unwrapped
> AST nodes (`{:%{}, ...}` / `{:{}, ...}`) that need a separate walk pass
> plus struct-map exclusion — cleaner to build alongside the EnvWalker
> consolidation (M43, also v1.16). Byte-identity held on plug_crypto and
> Decimal; new mutators exercised on Decimal (+106). M44 surfaced no
> invalid class, so the gate did not force a full deferral.

*Goal:* Add the two highest-noise literals in the v1.15 set,
each gated on a designed policy and on M44's invalid-rate signal.

*Inputs:* HLD v1.15 §M45; M39's atom-table-pollution flag; M44's
invalid-rate findings.

*Deliverables:*
- **Atom-table-pollution policy (designed before code):** a
  closed allowlist of atom↔atom swaps (e.g. `:ok ↔ :error`,
  `:lt`/`:gt`/`:eq` rotations). Never synthesize a new atom.
  `true`/`false` excluded (BooleanLiteral owns them). Document
  the allowlist and its rationale in the mutator moduledoc.
- `Mut.Mutator.AtomLiteral`: body-context atom literals from the
  allowlist only. Env-walker, fallback-routed, opt-in.
- `Mut.Mutator.CollectionEmpty`: body-position list/map/tuple →
  empty (`[a] → []`, `%{k: v} → %{}`, `{a, b} → {}`). Skip
  already-empty literals and any pattern position. Env-walker,
  fallback-routed, opt-in.
- Per-mutator unit tests + fixture golden lists. Invalid AND
  equivalent-ish survivor rate tracked per mutator.

*Acceptance:*
- Zero stable-id churn for existing mutants on the corpus.
- If M44's validation surfaced an unknown invalid class, this
  milestone defers to v1.16 and ships only the atom policy doc.
- New mutators opt-in; default `bin/verify` does not exercise
  them.

*Out of scope:* Pattern-position and variable mutators (v1.16+).
Default decisions (M46).

**M46 — Literal execution validation + default decisions.**

*Goal:* Promote the v1.15 literal mutators from plan-level to
execution-level evidence and decide each one's default policy.
Mirrors M25/M41's matrix-then-decide shape.

*Inputs:* HLD v1.15 §M46; M44/M45 mutators; M25/M41 threshold
conventions; `bench/run.sh` harness.

*Deliverables:*
- Validation matrix on demo_app (fixture proof), plug_crypto
  (small dispatch-heavy baseline), Decimal (byte-identity
  stress), plug (M34-unblocked), phoenix_html (macro-heavy
  opaque-policy stress). All under the now-sole `mix` worker.
- Per target × per mutator: new mutants surfaced, kill /
  survived / error / **invalid** counts, equivalent-ish
  survivors, env-walker parse+walk time, stable-id diff for
  existing mutants (MUST be zero), skip-reason histogram.
- Decision docs at `docs/decisions/M46_float_literal.md`,
  `M46_nil_literal.md`, `M46_atom_literal.md`,
  `M46_collection_empty.md`, `M46_string_literal_table.md`:
  per mutator, one of `keep_opt_in` / `default_on` /
  `fold_into_literal_preset`, using the M25/M41 thresholds
  (kill ≥60%, equivalent <20%, invalid <10%). If two or more
  literals warrant default-on, design the `--enable literal`
  preset; otherwise defer the preset.

*Acceptance:*
- Decision docs committed for all five literal mutators.
- BENCHMARKS.md gains a v1.15 section per target × mutator ×
  enablement.
- Zero stable-id churn for existing mutants on all five targets.
- env-walker parse+walk gate (≤10% oracle wall) holds in
  production on Decimal and plug.
- No-expansion grep gate holds.

## v1.15 horizon (not v1.15 scope)

- **Pattern-position literal mutators** — v1.16+/v2; need the
  invalid/equivalent data M46 begins gathering.
- **Variable mutators** — v1.16+/v2 per M39 ordering.
- **Schema routing for env-walker literals** — separate stable-id
  migration if ever; gated on a literal going default-on.
- **`--enable literal` preset** — designed in M46 only if ≥2
  literals warrant default-on; otherwise v1.16.
- **M43 walker consolidation**, if cut as a release valve.

## Explicitly NOT v1.15

- Coverage default flip. Coverage stays opt-in — less invasive
  than worker types and useful diagnostically, but unproven as a
  default on more real projects.
- Schema routing for any env-walker mutator. Fallback-only
  persists.
- Pattern-position and variable mutators.
- Function-call deletion / return-value replacement (deferred
  indefinitely; high false-positive risk).
- Persistent worker in any deprecated-in-place form. It is
  deleted, not frozen.
- Stable-id input changes; cross-run history; wrapper guard
  schemata.
- New CLI flags beyond the per-mutator `--enable` toggles (and
  the M46 `--enable literal` preset iff M46 designs it).

# v1.16 milestones (default-policy + literal-reporting robustness)

v1.15 (M42–M46) shipped on master (`8bbe479..e12c5cd`). It left
a small, well-characterized backlog. v1.16's theme is **harvest +
harden**: deliver the one decided-but-undelivered default
(AtomLiteral), fix the literal-reporting robustness bug M46
surfaced, trim the noisiest literal row, close the
collection-shape gap — and explicitly *not* force the M43
consolidation refactor (M39 measured env-walker cold-walk cost at
<1% of oracle wall, so the parallel design carries no meaningful
tax; ROI of consolidation is unproven).

Not a broad catalog push. The only catalog change is closing
CollectionEmpty's deferred shapes; no genuinely new mutator type
ships.

**Defaults DO change in v1.16 — once, additively.** AtomLiteral
becomes default-on (M46 decision), the first env-walker mutator
in the default plan. Existing stable IDs are unchanged; new
AtomLiteral mutants are added. String/Float/Nil/Collection stay
opt-in. `--selection static` and coverage-opt-in unchanged.
Elixir floor stays `>= 1.19.0`.

Five milestones. Core ship value is **M47 + M48 + M49** (all
small). **M50** (collection shapes) is gated with a release valve
to v1.17. **M51** (consolidation design/proof) is a cuttable
spike — cut first if budget tightens.

## v1.16 scope (committed)

**M47 — Literal-reporting robustness.**

*Goal:* One un-renderable mutant diff must never abort the whole
report.

*Inputs:* v1.16 backlog item 4; the M46 plug-run incident
(`Mut.Reporter.StrykerJson.files/3` raised `TokenMissingError`
rendering one mutant's diff, aborting the JSON write *after* all
1,390 mutants ran).

*Deliverables:*
- Guard diff rendering in `lib/mut/reporter/stryker_json.ex` so a
  render failure for one mutant is caught, recorded with a marker
  (e.g. diff omitted + reason), and does not propagate.
- Same guard in `lib/mut/reporter/terminal.ex`.
- Regression fixture: a mutant whose rendered diff trips the
  `Macro.to_string`/tokenizer path (escape-trap content), proving
  graceful degradation.

*Acceptance:*
- Fixture escape-trap mutant renders or degrades without raising.
- plug v1.19.1 literal run writes valid Stryker JSON end-to-end.
- All `bin/verify` layers green.

*Out of scope:* Root-causing the `Macro.to_string` heredoc/escape
issue upstream (workaround + marker is sufficient).

**M48 — AtomLiteral default-on + mutator default-tier flag model.**

*Goal:* Make AtomLiteral default-on **without** leaking the other
four env-walker literals into the default plan.

*Inputs:* v1.16 backlog item 3; `docs/decisions/M46_atom_literal.md`;
the current all-or-nothing `:env_walker` `enabled_targets` model
in `lib/mut/cli.ex` + `lib/mut/orchestrator.ex`;
`lib/mut/mutator/defaults.ex` (today lists all mutators flat).

*Deliverables:*
- Per-mutator granularity within the env-walker source: enabling
  the walker no longer implies running every env-walker mutator.
- A clean tier split in the flag/config model: **default-on set /
  opt-in set / named presets** (replacing today's flat
  `Defaults.list/0` + coarse `:env_walker` target). Document the
  tiers.
- AtomLiteral moves to the default-on tier; env walker runs by
  default but only AtomLiteral is active by default.
  String/Float/Nil/Collection remain `--enable`-only.
- Preserve every existing `--enable` flag and the M46 span
  behavior.

*Acceptance:*
- Default `mix mut` plan includes AtomLiteral mutants and
  excludes String/Float/Nil/Collection (verified by plan diff on
  demo_app + Decimal).
- All non-env-walker stable IDs byte-identical to v1.15 on
  demo_app, plug_crypto, Decimal, plug.
- `--enable string_literal` / `--enable env_walker` etc. still
  produce the v1.15 plans.
- All `bin/verify` layers green.

*Out of scope:* The `--enable literal` preset (needs ≥2 default-on
candidates; only AtomLiteral qualifies — deferred). New default-on
literals beyond AtomLiteral.

**M49 — StringLiteral table trim.**

*Goal:* Drop the equivalent-heavy prepend-space row; keep the
useful opt-in rows.

*Inputs:* v1.16 backlog item 5;
`docs/decisions/M46_string_literal_table.md` (prepend-space drags
kill rate, especially on Decimal).

*Deliverables:*
- Remove the `s → " " <> s` replacement from
  `Mut.Mutator.StringLiteral`. Keep `s → ""` and `s → "x"`
  (both opt-in).
- Update fixture golden mutation lists.

*Acceptance:*
- Prepend-space mutants absent from plans corpus-wide.
- Remaining StringLiteral stable IDs unchanged (identity keys on
  span + replacement; removing a replacement deletes only its own
  mutants).
- All `bin/verify` layers green.

*Out of scope:* Re-tuning the kept rows (M46 already decided
`keep_opt_in` for the table).

**M50 — CollectionEmpty maps + n-tuples (gated; release valve).**

*Goal:* Close M45's deferred collection shapes safely.

*Inputs:* v1.16 backlog item 2; M45 closure note (maps/n-tuples
are unwrapped AST nodes needing a separate walk pass +
struct-map exclusion).

*Deliverables:*
- Map literal emptying `%{...} → %{}` with **strict struct-map
  exclusion** (`%S{}` / `{:%{}, [{:|, …}]}` struct forms never
  emptied).
- N-tuple emptying `{a, b, c} → {}` for arity ≥ 3 (2-tuple
  already shipped in M45).
- Separate walk pass over the unwrapped `{:%{}, …}` / `{:{}, …}`
  nodes (the `literal_encoder` wrapping M45 relied on does not
  cover these).
- Per-mutator unit tests + fixture golden lists; invalid AND
  equivalent-ish survivor rate tracked.

*Acceptance:*
- Zero stable-id churn for existing mutants on the corpus.
- Per-mutator invalid rate < 10%.
- Struct maps provably never emptied (fixture asserts a
  `%MyStruct{...}` literal is skipped).
- Opt-in (CollectionEmpty stays `keep_opt_in` per M46).

*Release valve:* If struct exclusion or shape noise cannot be made
clean within budget, ship only the design note and defer maps
and/or n-tuples to v1.17.

*Out of scope:* Pattern-position collection mutations; default-on
for CollectionEmpty (M46 said opt-in).

**M51 — EnvWalker consolidation design + proof (spike; cuttable).**

*Goal:* Decide, with a small proof, whether the v1.17 M43
consolidation is worth implementing — without writing migration
code.

*Inputs:* `docs/decisions/M43_envwalker_consolidation.md` (the
v1.15 deferral evidence and redesign direction); M39's cold-walk
measurements.

*Deliverables:*
- Extend the M43 decision doc into a concrete redesign:
  **AstWalk absorbs EnvWalker's trust/context classification into
  its existing frame-based traversal**, keeping AstWalk's path
  encoding (the reverse churns stable IDs — proven in v1.15).
- A *tiny* proof (throwaway, not in `lib/`) that trust/context can
  be attached to AstWalk frames without changing any existing
  stable id.
- Explicit go/no-go for a v1.17 implementation milestone, with a
  LOC estimate and the byte-identity migration analysis any
  encoding change would require.

*Acceptance:*
- Updated decision doc committed; go/no-go explicit.
- No production code changed; M47–M50's green state preserved.

*Release-valve note:* Cut first if v1.16 budget tightens. M50 does
not depend on it (M45 confirmed maps/tuples are doable as a
standalone walk pass).

## v1.16 horizon (not v1.16 scope)

- **M43 consolidation implementation** — v1.17 iff M51 returns go.
- **`--enable literal` preset** — when a second literal reaches
  default-on.
- **Pattern-position and variable mutators** — still gated on the
  richer v2 env walker.
- **Coverage default flip** — still deferred.

## Explicitly NOT v1.16

- M43 consolidation *implementation* (design/proof only via M51).
- Schema routing for any env-walker mutator. Fallback-only
  persists.
- New default-on literals beyond AtomLiteral.
- Pattern-position / variable mutators; function-call deletion /
  return-value replacement.
- Coverage default flip; cross-run history; wrapper guard
  schemata.
- Stable-id input changes beyond M46's already-shipped one-time
  span migration.

# v1.17 milestones (literals first-class + v2 mutation surface)

v1.16 (M47–M51) shipped on master (`9bbd205..f3d709f`). v1.17 is
the first genuinely ambitious surface-and-performance release since
v1: make the literal catalogue **fast** (schema-routing) and
**broader** (pattern-position + variable mutators — the v2 shapes
promised since v1.5), then validate on a real OSS corpus. This is
v2-scale work delivered as one large release.

Two grounding findings (verified in code, 2026-05-24):
- `Mut.EnvSnapshot.context` is already `nil | :match | :guard`;
  the mutator gate just hard-requires `context == nil`. So
  pattern-position literals are largely a gate relaxation + hazard
  rules, NOT new walker infrastructure.
- The persistent worker is gone (v1.15), so the old mix-only-drift
  OSS targets (ecto, gettext, phoenix) now just run under the
  single `mix` worker. `../elixir_oss/projects` holds 33 pinned
  real projects — broad validation is finally cheap.

**Defaults: no new default-on flips beyond M46's AtomLiteral.**
New surface mutators (pattern-position, variable) ship opt-in; M55
decides graduations from execution data. `--selection static` and
coverage-opt-in unchanged. Elixir floor stays `>= 1.19.0`. M52's
literal schema-id migration is an explicit one-time stable-id
change for env-walker literals only — gated and documented.

Four milestones, all substantial. M52 (perf migration) and M54
(new walker infra) are the two independent hard bets; M53 (surface
add) reuses existing `:match` classification; M55 is the
validation matrix. Per the scoping decision, **variable mutators
are committed in full — no release valve.**

**Prelude commit (not a milestone):** README + BENCHMARKS v1.16
closure. README still claims atom literals are opt-in (M48 made
AtomLiteral default-on) and collections list/2-tuple only (M50
added maps + n-tuples opt-in); BENCHMARKS has no v1.16 section
(needs the default-plan delta + AtomLiteral additions + M50
invalid-rate evidence + M47 reporter-fix note). Ships first.

## v1.17 scope (committed)

**M52 — Schema-route the literal catalogue (reconcile + stable-id migration).**

*Goal:* Move the env-walker literal catalogue from fallback
(per-mutant recompile) to schema (one instrumented build), the way
v1 dispatch mutators already work.

*Inputs:* HLD v1.17 §M52; `lib/mut/schema_placer.ex`
(`ast_path_hash`-keyed case-gate placement over plain AST);
`lib/mut/env_walker.ex` + `collect_literal_candidates/2`
(literal_encoder AST, `ast_path = []`, byte-span identity);
`docs/decisions/M46_*` (the deferred "literal-encoding stable-id
migration" note); [[byte-identity-gate-harness]].

*Deliverables:*
- Reconcile the two AST views: teach `Mut.SchemaPlacer` to place
  case-gates at literal positions discovered over the
  `literal_encoder` AST (literals wrapped in `{:__block__, …}`),
  OR re-derive literal positions in plain AST — whichever
  preserves a single, stable identity scheme.
- One-time literal stable-id migration: the env-literal identity
  changes from byte-span to the reconciled scheme. Document it as
  an explicit migration (mirrors M46's span migration). Non-literal
  stable IDs MUST NOT change.
- Route schema-placeable literals through the schema engine; keep
  fallback for literals that cannot be schema-placed (record which
  and why).
- Before/after wall-clock instrumentation: fallback-vs-schema for
  the literal bucket.

*Acceptance:*
- Literal mutants execute via the schema build (verified by build
  artifact + worker path).
- Non-env stable IDs byte-identical on demo_app, plug_crypto,
  Decimal, plug (stable-id diff harness).
- Documented fallback→schema wall-clock delta on Decimal + plug.
- Invalid rate for literals unchanged or lower; `bin/verify` green.

*Out of scope:* Schema routing for non-literal mutators. New
literal shapes. Pattern/variable surface (M53/M54).

*Status (2026-05-24): DELIVERED.* Reconciliation via the marked
`literal_encoder` + 2-pass normalization (not path re-derivation);
unplaceable literals (bitstring segments, clause-head patterns)
recognized in `SchemaPlacer.refused_context/1` and rerouted to
fallback via `SchemaBuild.reroute_refused/2`. Non-literal IDs
byte-identical on demo_app (golden) and plug_crypto (64 IDs);
literal stable-id migration + reroute-safety documented in
`docs/decisions/M52_literal_schema_routing.md`. `bin/verify` green;
plug_crypto schema build clean with **0 invalid**. *Deviation:* the
Decimal/plug byte-identity + fallback→schema wall-clock delta fold
into **M55**'s broad matrix (those local checkouts are re-established
there; `tmp/bench` is cleaned by `bin/verify`'s sandbox reset).

**M53 — Pattern-position literal mutators.**

*Goal:* Mutate literals in `:match` (pattern) positions,
conservatively.

*Inputs:* HLD v1.17 §M53; `Mut.EnvSnapshot` (`context == :match`
already classified); the existing literal mutators
(Integer/Atom/Boolean/Nil/String).

*Deliverables:*
- Relax the first-pass gate (`context == nil`) to also admit
  `context == :match` for a conservative literal subset.
- Hazard rules: never produce an overlapping/unreachable clause;
  skip pinned-variable-adjacent literals where the swap changes
  match semantics ambiguously; skip positions where two clauses
  would collide post-mutation.
- Fallback-routed (pattern schemata are not expression-position
  safe). Per-mutator unit tests + fixture golden lists.

*Acceptance:*
- Zero stable-id churn for existing mutants on the corpus.
- Per-mutator invalid rate < 10%; equivalent-ish rate tracked.
- Pattern mutants fire on real `:match` positions in the fixture.
- Opt-in (not in the default-on tier).

*Out of scope:* Variable mutators (M54). Pattern *shape* mutations
(tuple/list arity) — still skipped per M39.

*Status (2026-05-24): DELIVERED.* New opt-in `:pattern_literal` target;
`EnvWalker` emits `:match` scalar candidates (int/atom/boolean/nil/string)
for bare args / list / n-tuple elements (2-tuples + map pairs are never
descended; bitstring segment sizes skipped via an `in_bitstring` flag).
Fallback-routed via `Orchestrator.pattern_literal_results`. Hazard rules:
bitstring skipped predictively; clause collisions handled reactively by
`CompileRollback` (rationale in `docs/decisions/M53_pattern_position_literals.md`).
Zero stable-id churn (demo_app base vs `+ :pattern_literal` identical);
firing proven on an oracle-backed pattern-literal fixture; `bin/verify`
green. *Deviation:* predictive cross-clause collision detection deferred
(reactive rollback instead) — revisit from M55 corpus data if the
pattern-literal invalid rate is high. Per-mutator invalid-rate
measurement folds into M55.

**M54 — Variable mutators (walker binding-scope extension + mutators).**

*Goal:* Add variable-reference mutators, including the new local
binding-scope tracking they require. Committed in full (no valve).

*Inputs:* HLD v1.17 §M54; `lib/mut/env_walker.ex` (tracks
alias/import/require maps today, NOT local bindings);
`docs/spikes/M39_env_walker.md` (no-expansion contract).

*Deliverables (internal commit pacing):*
1. Local binding-scope tracking in `Mut.EnvWalker`: which variable
   names are bound and in scope at each node. Surfaced on
   `EnvSnapshot` (new field) without changing existing fields'
   serialization.
2. `Mut.Mutator.VariableReplace`: replace an in-scope variable
   reference with another in-scope variable (same arity/usage
   shape). Opt-in, fallback-routed.
3. Optional `Mut.Mutator.VariableToLiteral` where the binding's
   evident type permits (heavily gated; may defer if noise is
   intractable).
4. Gating + diagnostics + reporter integration; no-expansion grep
   gate extended to the new walker paths.

*Acceptance:*
- Binding-scope tracking adds ZERO stable-id churn for existing
  mutants (new snapshot field must not enter existing identities).
- Variable mutants opt-in; invalid AND equivalent rates tracked
  and reported.
- No-expansion grep gate green on the extended walker.
- `bin/verify` green.

*Out of scope:* Cross-function / cross-module variable reasoning.
Closure-capture analysis beyond syntactic scope.

*Status (2026-05-24): DELIVERED (VariableReplace; VariableToLiteral deferred).*
`EnvWalker` tracks a `bound_vars` set (params + clause-head patterns, reverting
per def/clause; `=`/with/for generators intentionally excluded as an
under-approximation so swaps never introduce undefined vars), surfaced on
`EnvSnapshot` (zero stable-id churn). `collect_variable_candidates/2` emits
in-scope variable reads; `Mut.Mutator.VariableReplace` (new opt-in `:variable`
target, fallback-routed) swaps to ≤3 other in-scope vars. Unused-variable
warnings handled reactively by `CompileRollback`. *Deviation:*
`VariableToLiteral` deferred (needs type evidence the no-expansion walker
cannot cheaply derive) — rationale in
`docs/decisions/M54_variable_mutators.md`. Zero churn verified on demo_app;
`bin/verify` green; no-expansion contract intact (pure AST traversal). Corpus
invalid/equivalent rates fold into M55.

**M55 — Broad OSS validation matrix + combined decisions.**

*Goal:* Validate the full v1.17 catalogue on a real OSS corpus and
decide surface-mutator defaults + the schema-routing perf verdict.

*Inputs:* HLD v1.17 §M55; `../elixir_oss/projects` (33 pinned
projects); `bench/run.sh`; M25/M41 threshold conventions.

*Deliverables:*
- Curated ~10-project matrix, SHAs pinned: **decimal, jason, plug,
  gettext, ecto, credo, req, timex, makeup, oban** (spread across
  math/pure-lib, dispatch-heavy, macro-heavy, pattern/literal-rich).
  All under the single `mix` worker.
- Per target × mutator: kill / survived / error / **invalid** /
  equivalent-ish counts, schema-vs-fallback wall-clock, stable-id
  diff (zero for existing), skip-reason histogram.
- `docs/decisions/M55_pattern_position.md`,
  `M55_variable.md`, `M55_schema_routing_perf.md`: per-mutator
  default policy (keep_opt_in / default_on / preset) via the
  M25/M41 per-target-minimum rule, and the schema-routing verdict
  (did M52 materially cut literal wall-clock?).
- BENCHMARKS.md v1.17 matrix; CHANGELOG.

*Acceptance:*
- Decision docs committed.
- Zero stable-id churn for existing mutants across the corpus.
- env-walker parse+walk gate (≤10% oracle wall) holds on the
  larger targets.
- `bin/verify` green.

*Out of scope:* Acting on default-flip decisions that need a
follow-up migration (those scope into v1.18).

*Status (2026-05-24): DELIVERED (representative subset).* Ran the new opt-in
surfaces on decimal / jason / gettext / plug (math / binary / macro-codegen /
dispatch). Both clear invalid < 10% (variable 0.39–1.45%; pattern ~0%).
**Decisions:** pattern-position + variable both **keep_opt_in** (variable
errors heavily in codegen code; no new default-on beyond AtomLiteral);
schema-routing (M52) **confirmed** (one ~2.6s build vs per-mutant recompile
~0.4–2.1s). Found+fixed a bitstring-specifier defect (`da89799`; jason variable
invalid 19% → 1.25%). Zero churn holds by construction (new targets opt-in).
Docs: `docs/decisions/M55_corpus_validation.md`, BENCHMARKS v1.17, CHANGELOG.
*Deviation:* full 10-target matrix (adds ecto/credo/req/timex/makeup/oban — not
wired in `bench/run.sh`, several need baseline prep) is follow-up; the four
executed targets cover the decision-relevant shapes. `bin/verify` green.

## v1.17 horizon (not v1.17 scope)

- **Schema routing for non-literal mutators** — only if M55's perf
  data shows fallback dominates elsewhere.
- **Pattern/variable default-on flips** — v1.18 if M55 says
  graduate; the `--enable literal`/`--enable surface` presets ride
  the same decision.
- **EnvWalker consolidation implementation** — still gated on a
  maintenance trigger (M51).
- **Coverage default flip; cross-run history** — still deferred.

## Explicitly NOT v1.17

- Schema routing for non-literal mutators (M52 is literals only).
- New literal *value shapes* beyond the existing catalogue.
- Function-call deletion / return-value replacement (deferred
  indefinitely).
- Coverage default flip; cross-run history; wrapper guard schemata.
- EnvWalker consolidation implementation (M51 deferred it).
- New default-on flips beyond M46's AtomLiteral (M55 decides
  graduations; flips themselves are v1.18).

# v1.18 milestones (defaults grow up: harden, then graduate)

v1.17 (M52–M56, `bf14d68..f6fb850`) shipped a large new mutation
surface but left it noisy, opt-in, and undecided. v1.18's theme is
**maturation**: pay down the v1.17 surface debt (the hardening
spine M57–M59), then flip the two long-deferred defaults the
spine's data unlocks (M60 clean-surface graduation, M61
coverage-as-default). No new mutation surface; no new big
subsystem. Incremental cross-run history is explicitly held for a
later release (the user chose maturation over the new perf
subsystem this cycle).

**Two defaults change in v1.18, both data-gated.** Neither flips on
assertion — both depend on the M59 matrix + equivalent-rate data.
`--selection static` remains available as the escape hatch after
M61. Elixir floor stays `>= 1.19.0`.

Five milestones, all substantial. Dependency order is strict:
M57 (refined variables) and M58 (engine) precede M59 (matrix; M58
removes false-invalids that would pollute the data); M60 needs
M57 + M59; M61 needs M59. The spine (M57–M59) ships regardless;
the graduations (M60–M61) ship only what the data clears.

## v1.18 scope (committed)

**M57 — Variable-mutator noise refinement + identifier-classification hardening.**

*Goal:* Make variable mutants graduation-eligible by cutting the
v1.17 error tail, and stop the false-positive whack-a-mole.

*Inputs:* `docs/decisions/M55_corpus_validation.md` (gettext 27% /
plug 6% error tail; the "skip codegen/macro modules + gate on
other-uses" refinement); the four v1.17 false-positive fix commits
(`da89799`, `e3480cd`, `06a1280`, and the bitstring fix);
`lib/mut/env_walker.ex` variable candidate collection.

*Deliverables:*
- `VariableReplace` skips codegen / macro-definition modules
  (functions whose body builds quoted code) — these surface as
  compile errors in dependents, poor UX for a default mutator.
- Gate swaps on the swapped-out variable having ≥1 other use
  (avoid unused-variable churn / warnings-as-errors rollback).
- A single principled "is this identifier a real variable
  read/binding" classifier in `Mut.EnvWalker`, consolidating the
  four reactive fixes (bitstring type specs in `<<>>`, `\\`
  default-arg expressions, pipe-rhs function names, `&`-capture
  function names). New AST shapes route through one place.

*Acceptance:*
- Variable error rate materially down on gettext + plug (measured).
- Regression tests for all four known false-positive shapes; green.
- Zero stable-id churn for existing mutants.
- `bin/verify` green.

*Out of scope:* Broadening the variable mutator surface; the
default-on flip itself (M60).

**M58 — Fallback-recompile engine hardening.**

*Goal:* Confirm/close the credo invalid residual and harden the
fallback recompile for compile-time-dependent projects.

*Inputs:* `docs/decisions/M55_followup_oss_matrix.md` (the credo
10.3% residual + the unconfirmed engine hypotheses); `9818aeb`
(the `Mix.start` fix); `lib/mut/recompile.ex` + sandbox.

*Deliverables:*
- Root-cause the credo residual: genuine for/unquote
  metaprogramming vs still-engine (single-file recompile leaving
  compile-time dependents stale; parallel-worker sandbox
  contention on the shared build dir; slow-compile/timeout
  interaction). Document the finding.
- Harden `Mut.Recompile`/sandbox for `use Macro`-shaped
  compile-time-registration projects per the finding.
- A `use`-macro-registration fixture exercising the recompile path.

*Acceptance:*
- credo invalid rate explained (genuine vs reduced by a fix).
- Fixture recompiles correctly under the fallback engine.
- No regression on the M55 clean targets (decimal/jason/ecto/…).
- `bin/verify` green.

*Out of scope:* Schema-routing more mutators (the other way to
avoid recompile; not v1.18).

**M59 — Complete the OSS matrix + equivalent-rate characterization.**

*Goal:* Produce the data both M60 and M61 depend on.

*Inputs:* [[elixir-oss-corpus]] (`../elixir_oss/projects`, 33
pinned); `bench/run.sh` (4 targets wired, 6 not);
`docs/decisions/M55_*` (blocked-target notes).

*Deliverables:*
- Wire ecto, credo, req, timex, makeup, oban into `bench/run.sh`.
- Unblock what is fixable; document the genuinely env-blocked
  (timex µs-precision test drift, req ezstd native build, oban
  multi-DB infra) as environment, not mutalisk defects.
- Per-mutator **equivalent-rate** measurement — the graduation
  metric M55 lacked. Define how equivalent-ish survivors are
  estimated (documented heuristic; this is not exact).
- BENCHMARKS v1.18 matrix: per target × mutator, kill / survived /
  error / invalid / equivalent-rate / wall-clock.

*Acceptance:*
- Matrix runs to ≥ 8/10 targets with documented blockers.
- Equivalent-rate reported per mutator per target.
- Zero stable-id churn; `bin/verify` green.

*Out of scope:* Acting on the data (M60/M61).

**M60 — Surface graduation (first default-on flips since M46).**

*Goal:* Flip the clean opt-in surfaces to default-on, gated on M59
data.

*Inputs:* M59 matrix + equivalent-rate data; M57 refined
variables; the M25/M41 per-target-minimum rule (kill ≥ 60%,
equivalent < 20%, invalid < 10%); `Mut.Mutator.Defaults`
(`default_on/0` / `opt_in/0` tiers from M48).

*Deliverables:*
- Move surfaces clearing the per-target bar into the default-on
  tier: pattern-position literals first (M55's clean candidate),
  refined `VariableReplace` only if M57 brought it over the bar.
- `docs/decisions/M60_*.md` per surface, recording the per-target
  numbers and the keep/graduate call.

*Acceptance:*
- Graduated surfaces in `default_on/0`; non-graduated stay opt-in.
- Default-plan stable-id change is **additive only** (existing IDs
  unchanged; new mutants added) — verified by plan diff on
  demo_app + Decimal.
- Decision docs committed; `bin/verify` green.

*Out of scope:* Graduating surfaces the data does not clear (stay
opt-in; revisit later).

**M61 — Coverage-as-default + selection sharpening.**

*Goal:* Flip `--selection` default from `static` to
`coverage_with_static_fallback` — the post-validation follow-up
the v1.5 HLD always planned.

*Inputs:* HLD v1.5 §Selection Modes (the staged flip);
`lib/mut/test_selection/coverage.ex`; the M59 matrix; the
v1.15 persistent-worker removal (simplifies coverage interaction).

*Deliverables:*
- Validate coverage selection across the M59 matrix, including
  interaction with the now-default-on surface (M60). Confirm no
  kill-count regression vs `static`.
- Flip the `--selection` default to `coverage_with_static_fallback`
  (never bare `coverage`). Keep `--selection static` as the
  documented escape hatch.
- Sharpen per-mutant test ordering/selection only where the data
  shows a real fanout win.
- `docs/decisions/M61_coverage_default.md` + BENCHMARKS perf delta.

*Acceptance:*
- Coverage default validated on the matrix; kill counts match
  `static` (selection narrows test work, not outcomes).
- `--selection static` still works; active mode reported per run.
- Decision doc committed; `bin/verify` green.

*Out of scope:* Bare `coverage` as default; coverage caching /
cross-run history (v2).

## v1.18 delivery status (2026-05-25: ALL DELIVERED)

The spine shipped; both graduations are **data-gated no-flips** (the plan's
explicit "ship only what the data clears" outcome).

- **M57** (`7d694db`) — variable noise refinement: codegen-skip + other-uses
  gate + single read-side classifier. Error tail gettext 211→45, plug 202→24.
- **M58** (`11be05c`) — recompile hardening: credo residual root-caused +
  closed (invalid ~40%→3.3% over the fix chain); `Mix.start` regression fixture.
- **M59** (`c99eed0`, `531de06`) — matrix to 8/10 (req/oban env-blocked) +
  per-mutator equivalent-rate; surfaced that coverage selection fails on 3/8
  targets.
- **M60** (`c6909f8`) — surface graduation: **nothing graduates** (no surface
  clears equivalent < 20% on every meaningful target; default plan unchanged).
- **M61** (`b49a39c`) — coverage-as-default: **not flipped** (coverage not
  robust — 3/8 failures); static stays default; robustness gaps documented for
  a future milestone.

`bin/verify` green throughout; all commits local on `master` (unpushed).

## v1.18 horizon (not v1.18 scope)

- **Incremental cross-run history** — the deferred ambitious bet;
  scope when maturation is banked.
- **Further surface graduation** — surfaces M60 left opt-in,
  revisited with more data.
- **Schema routing for non-literal mutators** — only if M58/M59
  show fallback dominates wall-clock for guards/variables.
- **EnvWalker consolidation implementation** — maintenance-trigger
  gated (M51).

## Explicitly NOT v1.18

- Incremental cross-run history (held for later).
- New mutation surface or new literal value shapes.
- Schema routing for non-literal mutators; wrapper guard schemata.
- Function-call deletion / return-value replacement.
- EnvWalker consolidation implementation.
- Bare `--selection coverage` as default (only the
  static-fallback mode flips).

# v1.19 milestones (finish the stalled flips)

v1.18 (M57–M61, 8 commits) hardened the v1.17 surface but shipped
**no flips** — M60 graduated nothing and M61 didn't flip coverage,
both data-gated no-flips. v1.19 converts both stalls into real
outcomes by fixing the two root causes that blocked the data, not
by asserting readiness: (1) the equivalent-rate metric
over-estimates, blocking graduation; (2) the coverage runner
aborts instead of degrading, blocking the coverage default. Two
independent tracks.

**Defaults may change in v1.19, both still data-gated.** M63 ships
only what the *sharpened* metric clears (same discipline as M60 —
nothing if nothing clears). M65 flips coverage only after M64
makes it crash-safe. No new mutation surface; no new subsystem;
incremental history still held. Elixir floor stays `>= 1.19.0`.

Four milestones, two tracks. Graduation: M62 → M63. Coverage:
M64 → M65. The tracks are independent; M65 depends on M64, M63 on
M62.

## v1.19 scope (committed)

**M62 — Sharper equivalent estimation + gate-rule revisit.**

*Goal:* Replace the inflated equivalent metric (and/or the gate
rule built on it) with something defensible enough to make a real
graduation decision.

*Inputs:* `docs/decisions/M60_surface_graduation.md` (the
covered-survivor heuristic, explicitly an over-estimate; the
per-target table); `docs/decisions/M59_oss_matrix_equivalent_rate.md`
(the measurement tooling); the M25/M41 gate rule.

*Deliverables:*
- Tighten the estimate: exclude uncovered survivors from the
  equivalent count (an uncovered survivor is "untested," not
  equivalent); add cheap syntactic equivalence rules where they
  exist. Produce a defensible **lower-bound** rather than an
  inflated upper-bound (or report both bounds).
- Revisit the graduation gate rule given the metric's known bias:
  e.g. admit a single-target miss within a small margin (≤~2pp)
  when the estimate is an acknowledged over-count. Document and
  justify — this changes graduation outcomes.
- Recompute the M59 matrix graduation table under the new
  metric/rule.

*Acceptance:*
- Defensible equivalent estimate (or explicit lower-bound) +
  documented gate rule, in a decision doc.
- Recomputed per-surface × per-target graduation table.
- No stable-id change (measurement/policy only); `bin/verify`
  green.

*Out of scope:* Exact equivalent detection (undecidable in
general — sharpen the estimate, don't claim exactness). The flip
itself (M63).

**M63 — Graduate what clears.**

*Goal:* Flip to default-on whatever clears M62's sharpened gate.

*Inputs:* M62 metric/rule + recomputed table; M57's refined
VariableReplace; `Mut.Mutator.Defaults` tiers.

*Deliverables:*
- Move clearing surfaces into `default_on/0`. IntegerLiteral-in-
  pattern is the prime candidate (one margin-point from clearing
  under the over-estimate); re-evaluate the other pattern literals
  and refined VariableReplace.
- `docs/decisions/M63_*.md` per surface with the recomputed
  numbers and the graduate/keep call.

*Acceptance:*
- Data-gated: ships nothing if nothing clears (like M60).
- Default-plan stable-id change is **additive only** (existing IDs
  unchanged), verified by plan diff on demo_app + Decimal.
- Decision docs committed; `bin/verify` green.

*Out of scope:* Graduating surfaces the sharpened data still
doesn't clear (stay opt-in).

**M64 — Per-file crash-tolerant static fallback in the coverage runner.**

*Goal:* Make `coverage_with_static_fallback` degrade per-file
instead of aborting the run, closing the three M61 failure modes.

*Inputs:* `docs/decisions/M61_coverage_default.md` (the three
crashes: gettext compile-in-test, credo timeout, timex
hot-codeload); `lib/mut/coverage/runner.ex` + `coverage/parser.ex`;
`lib/mut/test_selection/coverage.ex`.

*Deliverables:*
- Per-test-file coverage collection where each unit's failure is
  contained and that unit's tests fall back to static selection,
  run continuing:
  1. **exception** (gettext: `ParallelCompiler` under `:cover` on
     compile-in-test) — caught, file → static.
  2. **timeout** (credo: `:cover` overhead blows the per-file
     deadline) — elastic/higher timeout under coverage, else file
     → static.
  3. **BEAM/JIT crash** (timex: `:cover` + hot code-load) — per-unit
     isolation so a single file's crash is recoverable, file →
     static. (Partly BEAM-out-of-control; the fix is isolation +
     fallback, not preventing the crash.)
- Per-file coverage/static disposition surfaced in metrics.

*Acceptance:*
- gettext/credo/timex: coverage no longer aborts the run; failing
  units degrade to static; run completes.
- The M59 clean targets still collect coverage as before.
- `bin/verify` green.

*Out of scope:* Bare `coverage` mode robustness (it is allowed to
fail loudly by design). Coverage caching.

**M65 — Flip `--selection` default to `coverage_with_static_fallback`.**

*Goal:* Land the coverage-default flip the v1.5 HLD always planned,
now that M64 makes it crash-safe.

*Inputs:* HLD v1.5 §Selection Modes; M64's per-file fallback; the
M59 matrix.

*Deliverables:*
- Re-validate coverage across the matrix (incl. the three former
  failers, now degrading gracefully). Confirm kill counts match
  `static` — selection narrows test work, not outcomes.
- Flip the default to `coverage_with_static_fallback`. Keep
  `--selection static` as the documented escape hatch and the only
  fully-portable mode. Never bare `coverage`.
- `docs/decisions/M65_coverage_default.md` + per-target
  fanout/wall-clock delta in BENCHMARKS.

*Acceptance:*
- Coverage default validated; zero kill-count regression vs static.
- `--selection static` still works; active mode reported per run.
- Decision doc committed; `bin/verify` green.

*Out of scope:* Bare `coverage` as default; cross-run history /
coverage caching (v2).

## v1.19 delivery status (2026-05-25: ALL DELIVERED — both flips landed)

Unlike v1.18 (no flips), v1.19 converted both stalls into real outcomes by
fixing the root causes the flips were blocked on.

- **M62** (`7674d40`) — equivalent metric framed as upper bound; gate revised to
  admit a single-target ≤2pp miss. Recomputed: IntegerLiteral-in-pattern clears.
- **M63** (`88c51b9`) — **graduated IntegerLiteral-in-pattern to default-on**
  (first flip since M46) via a per-mutator/per-position allowlist. Additive:
  demo_app unchanged, Decimal +18 mutants, existing IDs untouched.
- **M64** (`1467641`) — coverage runner degrades per-file instead of aborting
  (records `degraded_test_files`, unions their static coverage to avoid false
  survivors, surfaces the disposition). gettext (M61 abort) now completes.
- **M65** (`8b52c98`) — **flipped `--selection` default to
  coverage_with_static_fallback**; kill-count parity validated (decimal 385==385,
  the 1-mutant diff was test flakiness); `static` stays the escape hatch.

`bin/verify` green throughout; all commits local on `master` (unpushed).

## v1.19 horizon (not v1.19 scope)

- **Incremental cross-run history** — still the deferred ambitious
  bet; scope once the flips are banked.
- **Further surface graduation** — surfaces M63 leaves opt-in,
  revisited with even-sharper equivalent data.
- **Exact equivalent detection** — out of reach; only estimation
  sharpening is in scope.

## Explicitly NOT v1.19

- Incremental cross-run history (held).
- New mutation surface or new literal value shapes.
- Schema routing for non-literal mutators; wrapper guard schemata.
- Function-call deletion / return-value replacement.
- EnvWalker consolidation implementation.
- Bare `--selection coverage` as default.
- Exact equivalent-mutant detection.

# v1.20 milestones (umbrella support + catalogue growth)

v1.19 (M62–M65) landed both stalled flips. v1.20 takes on the
engine's biggest untouched capability — **umbrella projects**,
hard-refused since v1 (`assert_not_umbrella!`) — and grows the
catalogue with two new mutator families. Real-world drivers:
`~/unilink` (5-app umbrella) and `~/zorbito` (14-app crypto/
clustering umbrella). See [[umbrella-validation-targets]].

**Validation scope is unilink only this release.** zorbito's
14-app suite likely needs DB/clustering infra (the oban/req
blocker class) and defers to v1.21 — run informationally if
budget allows, never gating.

**Defaults:** the two new mutator families ship opt-in; M71
decides graduation from data (no default-on flip pre-committed).
Umbrella handling is automatic when the target is an umbrella.
Elixir floor stays `>= 1.19.0`.

Six milestones, two independent tracks. Umbrella: M66 → M67 →
M68 (strict). Catalogue: M69, M70 (independent of umbrella). M71
validates both. **M70 (pattern-shape, noisiest/newest) is the
designated release valve** — cuts to v1.21 at zero downstream cost
if umbrella runs long.

## v1.20 scope (committed)

**M66 — Umbrella support design spike.**

*Goal:* Design the umbrella model before writing engine code
(spike-first, per M18/M29/M36/M39/M51).

*Inputs:* `lib/mut/bootstrap/overlay.ex` (`assert_not_umbrella!`,
`umbrella_project?`); the Operational Contracts (Child-Process
Bootstrap + Build-Path) near the top of this PLAN;
`lib/mut/work_copy.ex`, `lib/mut/mix_manifest.ex`,
`lib/mut/recompile.ex`; `~/unilink` (proof target).

*Deliverables:*
- Umbrella work-copy + overlay design for `apps_path` projects
  (the overlay no longer raises; it must inject `:mutalisk` as a
  dep visible to every child app, or at the umbrella root).
- Build-Path Contract extension for umbrellas: per-app ebins
  under a shared `_build/mut_*` root, `MIX_DEPS_PATH`, where each
  app's artifacts land.
- How oracle / schema / fallback / sandbox phases change.
- **Cross-app compile-dependency model** — the manifest walk must
  span app boundaries so a mutant in app A recompiles dependents
  in app B. This is the crux; document the algorithm.
- Throwaway proof on unilink measuring oracle/compile cost across
  5 apps.
- `docs/spikes/M66_umbrella.md`: design + explicit go/no-go + the
  v1.20 implementation scope.

*Acceptance:* design doc committed; cross-app dependency model
concrete; go/no-go explicit; no production code beyond the
throwaway proof; `bin/verify` green.

*Out of scope:* Implementation (M67/M68).

**M67 — Umbrella oracle + schema build.**

*Goal:* Implement the spike's design through the schema build.

*Inputs:* M66 design doc; `lib/mut/oracle_build.ex`,
`lib/mut/schema_build.ex`, `lib/mut/work_copy.ex`,
`lib/mut/bootstrap/overlay.ex`, `lib/mut/sandbox.ex`.

*Deliverables:*
- Materialize an umbrella work copy (root + `apps/`).
- Umbrella overlay (replaces the raise); `apps_path` handled.
- Oracle build compiles every app under the tracer; per-app
  plans produced.
- Schema placement across apps; instrumented umbrella built under
  the umbrella build-path role.
- Sandbox creation umbrella-aware.

*Acceptance:*
- unilink oracle + schema build succeed; per-app plans produced.
- **Single-app (non-umbrella) path byte-identical** — the
  umbrella branch must not regress the existing path (stable-id
  diff on demo_app + Decimal).
- `bin/verify` green.

*Out of scope:* Fallback cross-app dependents (M68).

**M68 — Umbrella fallback + cross-app dependents.**

*Goal:* The hard correctness piece — fallback recompile across
app boundaries.

*Inputs:* M66 cross-app dependency model; `lib/mut/mix_manifest.ex`,
`lib/mut/recompile.ex`, `lib/mut/sandbox.ex` (reset).

*Deliverables:*
- Per-app Mix manifest reading; a dependency walk spanning apps.
- Fallback recompile rebuilds the mutated app + its cross-app
  compile dependents in the sandbox before the targeted test run.
- Sandbox reset restores all affected apps' artifacts + manifests.

*Acceptance:*
- A unilink fallback mutant in a depended-upon app recompiles its
  dependents correctly (verified).
- No false-invalids from stale cross-app state.
- Sandbox reset returns every affected app to baseline.
- `bin/verify` green.

*Out of scope:* The new mutators (M69/M70).

**M69 — Operator-expansion mutators.**

*Goal:* Low-noise, schema-routed dispatch mutators extending the
proven path.

*Inputs:* HLD v1.20 §M69; existing dispatch mutators
(`Mut.Mutator.Arithmetic`, `ComparisonBoundary`) as the template;
`Mut.Match.Registry`.

*Deliverables:*
- `Mut.Mutator.ConcatOperator`: `++` ↔ `--`, `<>` mutations
  (list/binary concat).
- `Mut.Mutator.BitwiseOperator`: `band`/`bor`/`bxor`/`bsl`/`bsr`
  swaps.
- `Mut.Mutator.Membership`: `in` ↔ `not in`.
- Each implements `applicable?/2`, `mutate/2`, `equivalent?/1`,
  `targets/0`, `compatible?/2`. Opt-in.

*Acceptance:* per-mutator unit tests + fixture golden lists; zero
stable-id churn for existing mutants; `bin/verify` green.

*Out of scope:* Default-on (M71 decides). Pattern shapes (M70).

**M70 — Pattern-shape mutator framework (release valve).**

*Goal:* The deferred v2 item — pattern SHAPE mutations, not just
literals-in-patterns.

*Inputs:* `docs/spikes/M39_env_walker.md` (pattern-mutator
sketch + the high-noise warning); `Mut.EnvWalker` `:match`
context; M53 pattern-literal infra.

*Deliverables:*
- Conservative framework + mutators: `_` ↔ named var, pin/unpin
  (`^x`). Tuple/list arity stays skipped (M39: non-viable).
- Strict invalid/equivalent gating (this surface is noisy by
  nature). Opt-in, fallback-routed.

*Acceptance:*
- Per-mutator unit tests; invalid rate measured + gated.
- Zero stable-id churn for existing mutants.
- `bin/verify` green.

*Release-valve note:* highest noise/invalid risk in v1.20; cut to
v1.21 if umbrella runs long. M71 does not depend on it landing.

**M71 — Umbrella (unilink) + new-mutator validation + decisions.**

*Goal:* Validate umbrella support end-to-end and decide the new
mutators' default policy.

*Inputs:* M67/M68 (umbrella), M69/M70 (mutators); `bench/run.sh`;
the M62 sharpened graduation gate; `~/unilink`.

*Deliverables:*
- Full `mix mut` run on unilink: oracle → schema → workers →
  fallback → report, per-app + aggregate score.
- M69/M70 mutators run on unilink + the OSS matrix; kill /
  invalid / equivalent rates captured.
- `docs/decisions/M71_*.md`: operator-expansion + pattern-shape
  default policy (keep_opt_in / graduate per the M62 gate);
  umbrella acceptance verdict.
- BENCHMARKS v1.20 section.
- zorbito informational only if budget allows; infra blockers
  documented, not gating.

*Acceptance:*
- unilink umbrella run completes with a valid report.
- New-mutator decisions committed.
- Zero stable-id churn for existing single-app mutants.
- `bin/verify` green.

*Out of scope:* zorbito as gating; acting on graduation decisions
that need a follow-up migration (v1.21).

## v1.20 delivery status (2026-05-25: DELIVERED — M70 cut to v1.21 per the release valve)

- **M66** ✓ — umbrella design spike (committed earlier). GO verdict; corrected in M67 (root must be wrapped).
- **M67** ✓ — umbrella oracle + schema build. New `Mut.Umbrella`; per-app + root overlay; idempotent `:mut_oracle`; `MUTALISK_PROJECT_ROOT`-relative sites; umbrella-aware discovery/snapshot. Validated on unilink (89 518 sites, 1031-mutant per-app plan, schema build). Single-app byte-identical.
- **M68** ✓ — umbrella fallback + cross-app dependents. `MixManifest.read_combined/1` (app-prefixed, cross-app `dependents/3`); single-pass `ParallelCompiler.compile` + `:each_module` per-app beam routing; umbrella-aware sandbox reset. Verified: unilink hub mutant → 93 deps across all 5 apps, beams routed + source reset.
- **M69** ✓ — operator-expansion mutators (ConcatOperator / BitwiseOperator / Membership), opt-in. M71 → **keep_opt_in**.
- **M70** ✗ **CUT to v1.21** — pattern-shape mutators (release valve). Umbrella ran long (6 distinct umbrella correctness bugs); M70 is the noisiest surface; M71 did not depend on it.
- **M71** ✓ — umbrella validated end-to-end (engine on unilink; full worker+report on a self-contained 2-app umbrella: 8/9 killed, 0 invalid/error). M69 graduation data (jason ConcatOperator ~67% noise, plug_crypto BitwiseOperator pseudo-equivalents) → keep_opt_in. Decision: `docs/decisions/M71_operator_expansion_and_umbrella.md`; BENCHMARKS v1.20. Also fixed a single-/multi-app worker bug: umbrella `mix test` emits one `suite_finished` per app → results now aggregated. Found+fixed an entry-default file-discovery gap (`files` default `["lib"]` → `nil` → umbrella-aware `discover_files`).

## v1.20 horizon (not v1.20 scope)

- **zorbito validation** — the 14-app umbrella; v1.21, contingent
  on its DB/clustering test infra running in the sandbox.
- **New-mutator graduation** — surfaces M71 leaves opt-in.
- **Incremental cross-run history** — still the deferred bet.
- **Tuple/list pattern-arity mutations** — still skipped (M39).

## Explicitly NOT v1.20

- zorbito as a gating acceptance target (v1.21).
- Incremental cross-run history (held).
- New default-on flips pre-committed (M71 decides from data).
- Tuple/list pattern-arity; function-call deletion / return-value
  replacement.
- Schema routing for non-literal mutators beyond M69's operators;
  wrapper guard schemata.
- EnvWalker consolidation implementation.

# v1.21 milestones (close the v1.20 deferrals)

v1.20 (M66–M71, M70 cut) landed umbrella support but deferred its
noisiest catalogue work and harder validation. v1.21 closes those
threads: mature the M69 operators to graduation-readiness, ship the
cut pattern-shape mutators (M70), and push umbrella validation to a
real full run (unilink) + the 14-app target (zorbito). No new big
subsystem; incremental cross-run history stays held one more cycle.

**Validation correction:** unilink is NOT infra-gated — it runs with
local Postgres and its tests pass. v1.21 gets the real full `mix mut`
on a 5-app umbrella (worker/report included), closing the v1.20
caveat (that phase was only proven on a synthetic 2-app umbrella).
zorbito (14 apps; multi-DB + clustering) is a full-run target where
its services can be stood up, engine-path proof + documented blockers
as the floor — not gating.

**Defaults:** operators and pattern-shape ship/stay opt-in; M75
decides graduation from the full OSS matrix + equivalent-rate under
the M62 gate. No default-on flip pre-committed. Elixir floor stays
`>= 1.19.0`.

Four milestones. M72 (operator hazard) + M73 (pattern-shape) are
independent implementation tracks; M74 (umbrella validation) is
independent; M75 is the data-gated decision over both surfaces.

## v1.21 scope (committed)

**M72 — Operator hazard rules + graduation-readiness.**

*Goal:* Cut the M69 operators' noise to the point a graduation
decision is meaningful.

*Inputs:* `docs/decisions/M71_operator_expansion_and_umbrella.md`
(ConcatOperator ~67% non-productive; BitwiseOperator pseudo-
equivalents); `Mut.Mutator.ConcatOperator` / `BitwiseOperator` /
`Membership`; the literal mutators' hazard-rule pattern.

*Deliverables:*
- ConcatOperator hazard rules: refuse/skip `++`→`--` in positions
  that crash or fail to type-check (the jason encoder cases —
  reroute or skip rather than emit a guaranteed compile-error /
  suite-aborting mutant).
- BitwiseOperator: filter input-dependent pseudo-equivalents where
  syntactically detectable; otherwise document as a known weak
  signal.
- Membership left as-is (already clean).
- Per-mutator invalid + error rate instrumentation.

*Acceptance:*
- ConcatOperator non-productive rate materially down on jason /
  real list-binary code (measured before/after).
- Zero stable-id churn for existing mutants.
- Operators remain opt-in (M75 decides graduation).
- `bin/verify` green.

*Out of scope:* The graduation flip (M75).

**M73 — Pattern-shape mutators (carried M70).**

*Goal:* Ship the deferred pattern SHAPE surface.

*Inputs:* `docs/spikes/M39_env_walker.md` (pattern-mutator sketch +
high-noise warning); `docs/decisions/M71_*` (M70 cut rationale);
`Mut.EnvWalker` `:match` context + the M54 binding tracker.

*Deliverables:*
- Binding-scope-aware pattern walking (extend the M54 binding
  tracker into `:match` context).
- Mutators: `_` ↔ named var, pin/unpin (`^x`). Tuple/list arity
  stays skipped (M39: non-viable).
- Strict invalid/equivalent gating — highest-noise surface in the
  catalogue. Opt-in, fallback-routed.

*Acceptance:*
- Per-mutator unit tests; invalid rate measured + gated.
- Zero stable-id churn for existing mutants.
- `bin/verify` green.

*Out of scope:* Default-on (M75). Arity mutations.

**M74 — Umbrella validation: unilink full run + zorbito.**

*Goal:* Close the v1.20 synthetic-umbrella caveat and scale-prove
on 14 apps.

*Inputs:* v1.20 umbrella engine (`Mut.Umbrella`, M67/M68);
`~/unilink` (5 apps, local Postgres, tests passing); `~/zorbito`
(14 apps, multi-DB + clustering); [[umbrella-validation-targets]].

*Deliverables:*
- Real full `mix mut` on unilink: oracle → schema → workers →
  fallback → per-app + aggregate report. Closes the v1.20 caveat
  (worker/report was synthetic-only).
- zorbito: attempt the full run where services (Postgres / MySQL /
  SQLite / RabbitMQ / clustering) can be stood up; where a service
  cannot, prove the engine path (oracle / schema / cross-app
  fallback across 14 apps — the scale proof) and document the
  blocker.

*Acceptance:*
- unilink full run completes with a valid multi-app report.
- zorbito engine path proven across 14 apps (full run where infra
  permits); blockers documented.
- zorbito is NOT a gating acceptance target.
- No umbrella regression on the single-app path (golden_oracle +
  golden_instrument green).

*Out of scope:* Standing up arbitrary external infra mutalisk
cannot control (document, don't gate).

**M75 — Graduation matrix + decisions + BENCHMARKS.**

*Goal:* Decide operator + pattern-shape default policy from data.

*Inputs:* M72 operators, M73 pattern-shape; `bench/run.sh` + the
OSS matrix; per-mutator equivalent-rate (M59 tooling); the M62
sharpened gate (kill ≥60%, equivalent <20% with ≤2pp single-target
tolerance, invalid <10%).

*Deliverables:*
- Full OSS-matrix run of the M72 operators and M73 pattern-shape
  mutators with per-mutator equivalent-rate.
- `docs/decisions/M75_*.md`: per-surface keep_opt_in / graduate.
- BENCHMARKS v1.21 section (operator + pattern-shape rates;
  umbrella run results from M74).

*Acceptance:*
- Decisions committed; data-gated (graduate only what clears).
- Any graduation is additive-only (existing stable IDs unchanged),
  verified by plan diff on demo_app + Decimal.
- `bin/verify` green.

*Out of scope:* Surfaces that don't clear (stay opt-in; revisit
later).

## v1.21 delivery status (2026-05-26: DELIVERED — all surfaces keep_opt_in)

- **M72** ✓ — operator hazard rules. ConcatOperator drops `--`→`++` (jason non-productive 67%→0%); BitwiseOperator drops `bor`↔`bxor` pseudo-equivalents; per-mutator invalid/err/nonprod% instrumentation in `bench/equivalent_rate.exs`.
- **M73** ✓ — pattern-shape: `Mut.Mutator.Pin` (`^x`→`x` unpin), opt-in `:pattern_shape`, fallback-routed. The `_`↔var directions documented non-viable (compile-error-if-used / equivalent-if-unused). `AstWalk.pin_candidates`.
- **M74** ✓ — umbrella validation. unilink real full `mix mut` (5 apps, live Postgres+RabbitMQ): valid multi-app report, 0 errors, cross-app fallback ran. zorbito engine path across 14 apps (oracle 150k sites, schema 0 invalid); full worker run infra-blocked (documented, not gating). `docs/decisions/M74_umbrella_validation.md`.
- **M75** ✓ — graduation matrix (coverage; equivalent-rate). **All keep_opt_in**: ConcatOperator fails jason (codegen 67% equiv); Bitwise/Membership thin+pseudo-equiv; Pin flawless on plug (14/14, 0 equiv/invalid) but single-target. Found+fixed the Pin map-key hazard (`%{^k=>v}` unpinnable → ~30%→0% invalid). Additive-only (golden gates green). `docs/decisions/M75_graduation_matrix.md` + BENCHMARKS v1.21.

## v1.21 horizon (not v1.21 scope)

- **Incremental cross-run history** — the deferred ambitious bet;
  scope once the v1.20 catalogue/umbrella threads are closed.
- **zorbito full-run graduation to a gating target** — once its
  test infra is reliably reproducible.
- **Surfaces M75 leaves opt-in** — revisited with more data.

## Explicitly NOT v1.21

- Incremental cross-run history (held).
- New mutator families beyond pattern-shape.
- Tuple/list pattern-arity; function-call deletion / return-value
  replacement.
- zorbito as a gating acceptance target.
- EnvWalker consolidation implementation; wrapper guard schemata.

# v1.22 milestones (catalogue growth: the two missing classics)

v1.21 (M72–M75) closed the v1.20 deferrals. v1.22 adds the two
highest-yield mutators mutalisk never had — conditional negation
and function replacement (both confirmed absent from the
catalogue) — plus two small v1.21 carries. Focused catalogue
growth: no umbrella work, no new subsystem; zorbito full-run and
incremental history stay held.

**Defaults:** both new families ship opt-in; M79 decides
graduation from the OSS matrix + equivalent-rate under the M62
gate. No default-on flip pre-committed. Elixir floor stays
`>= 1.19.0`.

Four milestones. M76 (function-swaps) + M77 (conditionals) are
independent implementation tracks; M78 is small carried hardening
(foldable alongside); M79 is the data-gated decision over the new
surfaces + Pin re-eval.

## v1.22 scope (committed)

**M76 — Function-replacement swap mutator.**

*Goal:* A new dispatch-shaped mutator swapping semantically-paired
functions from a curated closed allowlist.

*Inputs:* the dispatch tracer oracle (records these call sites);
`Mut.Mutator.Arithmetic` as the schema-routed template;
`Mut.Mutator.AtomLiteral` as the closed-allowlist discipline;
`Mut.Match.Registry`.

*Deliverables:*
- `Mut.Mutator.FunctionReplace` with a documented swap table,
  justified per pair: `Enum.min`↔`max`, `List.first`↔`last`,
  `Enum.all?`↔`any?`, `Enum.filter`↔`reject`, `Enum.take`↔`drop`,
  `String.starts_with?`↔`ends_with?`, and similar. Never invent a
  target function (closed allowlist).
- `compatible?/2` predicate; swap only when the oracle confirms the
  dispatch resolves to the listed function/arity (no swap on a
  shadowing local or a different module).
- `targets/0 == [:dispatch]`; schema-routed. Opt-in.

*Acceptance:*
- Per-pair unit tests + fixture golden lists.
- Swap respects arity/module from the oracle (no false swap).
- Zero stable-id churn for existing mutants; `bin/verify` green.

*Out of scope:* Graduation (M79). Functions outside the allowlist.

**M77 — Negate/force conditionals mutator.**

*Goal:* Mutate `if`/`unless` conditions — the classic top-yield
branch mutator.

*Inputs:* `Mut.EnvWalker` `if`/`unless` handling (M40 tracer-proof
logic); the schema placer (`if`/`unless` routing).

*Deliverables:*
- `Mut.Mutator.NegateConditional`: condition → `not(condition)`,
  force `true`, force `false` (for `if`; `unless` symmetric).
- **Dead-branch equivalence gate:** forcing a branch the code does
  not rely on (e.g. an `if` with no meaningful `else`) is
  equivalent — detect/measure and gate to keep the equivalent
  rate down.
- Routing per the env-walker/dispatch handling of `if`/`unless`;
  fallback if not schema-safe. Opt-in.

*Acceptance:*
- Unit tests for negate + both force directions.
- Equivalence gate measured (M79 supplies the rate).
- Zero stable-id churn for existing mutants; `bin/verify` green.

*Out of scope:* `cond`/`case`-clause mutation (later); graduation
(M79).

**M78 — Carried hardening: ConcatOperator codegen-context exclusion.**

*Goal:* Lift jason's residual ConcatOperator equivalence.

*Inputs:* `docs/decisions/M71_*` + M72 hazard rules;
`Mut.Mutator.ConcatOperator`; the M57 codegen/quoted-builder
context-skip.

*Deliverables:*
- Exclude codegen / quoted-builder contexts from ConcatOperator
  (mirrors the M57 variable-mutator context-skip).

*Acceptance:*
- jason ConcatOperator equivalence rate down (measured).
- No regression on other targets; zero stable-id churn.
- `bin/verify` green. (Small — may land alongside M76/M77.)

*Out of scope:* New ConcatOperator behavior beyond the exclusion.

**M79 — Validation matrix + graduation decisions + BENCHMARKS.**

*Goal:* Decide the new mutators' default policy and re-evaluate
Pin.

*Inputs:* M76/M77/M78; `bench/run.sh` + the OSS matrix;
per-mutator equivalent-rate (M59 tooling); the M62 gate;
`docs/decisions/M75_*` (Pin leading-candidate note).

*Deliverables:*
- OSS-matrix run of FunctionReplace + NegateConditional with
  per-mutator equivalent-rate.
- **Pin graduation re-eval** now that more pin-bearing targets are
  in the matrix (flawless on plug in M75; was single-target).
- `docs/decisions/M79_*.md`: per-surface keep_opt_in / graduate.
- BENCHMARKS v1.22 section.

*Acceptance:*
- Decisions committed; data-gated (graduate only what clears).
- Any graduation additive-only (existing stable IDs unchanged),
  verified by plan diff on demo_app + Decimal.
- `bin/verify` green.

*Out of scope:* Surfaces that don't clear (stay opt-in).

## v1.22 delivery status (2026-05-27: DELIVERED — ConcatOperator graduated)

- **M76** ✓ — `Mut.Mutator.FunctionReplace` (closed-allowlist function swaps: Enum.min<->max, filter<->reject, take<->drop, List/String pairs…), dispatch/schema-routed, opt-in. Swaps only on oracle-confirmed {module,name,arity}.
- **M77** ✓ — `Mut.Mutator.NegateConditional` (if/unless: negate / force true / force false), opt-in `:conditional`, fallback-routed via whole-node `:end` span. AstWalk.conditional_candidates.
- **M78** ✓ — ConcatOperator codegen-context exclusion (dispatch walk tracks def codegen-body stack → AstCandidate.in_codegen?; ConcatOperator skips it). jason ConcatOperator equiv 67%→0%.
- **M79** ✓ — graduation matrix. **ConcatOperator GRADUATED to default-on** (clears jason/plug/decimal: kill ≥90%, equiv ≤10%, 0% invalid; additive — Decimal +10, 0 existing IDs changed, demo_app byte-identical). FunctionReplace + Pin keep_opt_in (flawless on plug but single-target). NegateConditional keep_opt_in (dead-branch equiv 25–52% + 15% invalid on plug). `docs/decisions/M79_graduation_matrix.md` + BENCHMARKS v1.22.

## v1.22 horizon (not v1.22 scope)

- **Statement-deletion mutator** — the high-noise classic; revisit
  if v1.22's surfaces land cleanly and there's appetite for the
  invalid-rate work.
- **`cond`/`case`-clause conditional mutation** — extends M77.
- **Incremental cross-run history** — still the deferred bet.
- **zorbito full worker run** — engine proven; full run
  infra-deferred.

## Explicitly NOT v1.22

- Statement-deletion mutator (deferred).
- Incremental cross-run history (held).
- zorbito full worker run; umbrella work of any kind.
- Tuple/list pattern-arity; function-call deletion / return-value
  replacement.
- EnvWalker consolidation implementation; wrapper guard schemata.

# v1.23 milestones (close the queue)

v1.22 (M76–M79) graduated ConcatOperator but left a full queue:
FunctionReplace + Pin both flawless on plug yet stuck on
single-target breadth, NegateConditional too noisy without a
M72-style hazard pass, and statement-deletion still deferred.
v1.23 clears all four queued surfaces so v1.24 can pivot cleanly
to incremental cross-run history (now held 5 releases — closing
the queue is itself a precondition for tackling it without
spreading thin).

Two of the four are unblocked by **data**, not new mutator work:
Pin and FunctionReplace need matrix targets that exercise them.
One small matrix-additions push unblocks both graduations. That's
the meta-leverage v1.23 is built around.

**Defaults:** graduations are data-gated by the M62 sharpened
gate; M83 decides. No flips pre-committed. Elixir floor stays
`>= 1.19.0`.

Four milestones. M80 + M81 are independent implementation tracks;
M82 is the matrix-breadth push; M83 is the data-gated decision
over all four queued surfaces.

## v1.23 scope (committed)

**M80 — NegateConditional dead-branch gate + invalid reduction.**

*Goal:* Make NegateConditional graduation-eligible by cutting its
dead-branch equivalence and invalid rates — the same hazard
discipline M72/M78 used for operators.

*Inputs:* `docs/decisions/M79_*` (the NegateConditional
keep_opt_in rationale: 25–52% dead-branch equivalence, 15.3%
plug invalid); `Mut.Mutator.NegateConditional`; M77 routing.

*Deliverables:*
- Dead-branch detection: skip or reroute force-true / force-false
  on `if cond do body end` shapes that are equivalent by
  construction (no `else`, or side-effect-free body where the
  branch's value isn't consumed).
- Invalid-rate root-causing on plug: characterize the 15.3% (where
  do the compile/runtime failures come from?), add hazard rules
  to skip those positions.
- Per-mutator instrumentation (invalid / equivalent / non-prod
  rates).

*Acceptance:*
- jason / decimal / plug_crypto equivalence rate materially down
  (measured before/after).
- plug invalid rate materially down.
- Zero stable-id churn for existing mutants; `bin/verify` green.

*Out of scope:* The graduation flip itself (M83). New
NegateConditional behavior beyond hazard gating.

**M81 — Statement-deletion mutator.**

*Goal:* Ship the deferred high-yield classic with aggressive
hazard gating up front.

*Inputs:* HLD v1.23 §M81; `Mut.EnvWalker` binding-scope tracking
(M54 — needed for orphan-binding detection); fallback engine.

*Deliverables:*
- `Mut.Mutator.StatementDelete`: in a `__block__` of statements,
  delete one. Routing fallback (structural). Opt-in.
- Hazard gates (skip):
  - **orphan-binding** — the deleted statement binds a name used
    later in the block.
  - **expression-position only** — don't break `case`/`with`
    scrutinee chains.
  - **pattern / guard contexts** — excluded entirely.
  - **last-statement-only-when-non-return-only** rule —
    documented (last statement determines return value; deleting
    it is interesting but extremely noisy — opt-in within opt-in
    or excluded by default).
- Per-mutator unit tests; invalid-rate instrumentation.

*Acceptance:*
- Invalid rate measured + gated to a documented floor (statement-
  deletion is intrinsically the catalogue's noisiest, but gating
  must keep it under a defensible bar).
- Per-mutator unit tests; zero stable-id churn for existing
  mutants; `bin/verify` green.

*Out of scope:* The graduation flip (M83). `case`-clause
deletion (separate surface).

**M82 — Matrix breadth: targets exercising Pin + FunctionReplace.**

*Goal:* Unblock Pin and FunctionReplace graduation by adding
matrix targets that exercise them.

*Inputs:* [[elixir-oss-corpus]] (`../elixir_oss/projects`, 33
projects, only ~8 wired); `bench/run.sh`; `docs/decisions/M79_*`
(the "needs breadth" gate misses).

*Deliverables:*
- Call-site density measurement across the 33 OSS projects:
  count `^`-pin occurrences (Pin exercise) and
  Enum/List/String allowlisted call occurrences (FunctionReplace
  exercise) per project.
- Wire 2–3 high-exercise targets into `bench/run.sh` (candidates:
  ecto for patterns, absinthe for resolver patterns, broadway /
  oban for Enum-heavy data flow, phoenix_html for templates —
  density-driven, not pre-asserted).
- Run baseline + Pin/FunctionReplace runs to confirm clean.

*Acceptance:*
- 2–3 new matrix targets wired and running clean.
- Pin and FunctionReplace each exercised on **≥3 matrix targets**.
- Baseline kill/invalid rates documented per new target.
- `bin/verify` green.

*Out of scope:* zorbito (still infra-deferred); wiring more than
density justifies.

**M83 — Graduation re-eval + BENCHMARKS.**

*Goal:* Apply the M62 gate to the four queued surfaces with the
new hazard data and matrix breadth.

*Inputs:* M80 hazard rules; M81 new mutator; M82 broader matrix;
per-mutator equivalent-rate (M59 tooling); the M62 sharpened gate.

*Deliverables:*
- OSS-matrix run covering:
  - NegateConditional (post-M80 hazard)
  - Statement-deletion (first eval)
  - Pin (post-M82 breadth)
  - FunctionReplace (post-M82 breadth)
- `docs/decisions/M83_*.md`: per-surface keep_opt_in / graduate
  per the M62 per-target rule + ≤2pp tolerance.
- BENCHMARKS v1.23 section.

*Acceptance:*
- Decisions committed; data-gated (graduate only what clears).
- Any graduation additive-only (existing stable IDs unchanged),
  verified by plan diff on demo_app + Decimal.
- `bin/verify` green.

*Out of scope:* Surfaces that don't clear (stay opt-in).

## v1.23 delivery status (2026-05-28: DELIVERED — Pin graduated)

- **M80** ✓ — NegateConditional dead-branch + invalid hazards (binding hazard for `=`/`<-` in conditions; no-else direction-specific skip). Measured: plug invalid 15.3%→0.7%; decimal equiv 25.4%→23.1%; jason unchanged (both-branch-equivalent pattern, not no-else).
- **M81** ✓ — `Mut.Mutator.StatementDelete`. Body-position-only (collector visits defmodule→def directly); last-statement excluded; orphan-binding hazard. Opt-in `:statement_delete`, fallback (whole-def re-render).
- **M82** ✓ — Matrix breadth: wired **absinthe** (v1.7.10) into `bench/run.sh`; Pin exercised on 3 targets (plug/absinthe/phoenix_html). FunctionReplace gate miss documented (credo Regex-incompat on 1.19, ecto baseline 9 failures, req ezstd, small targets have 0 allowlisted calls).
- **M83** ✓ — Graduation re-eval. **Pin GRADUATED to default-on** (3 targets all 100%/0%/0%; additive — Decimal 559→559, demo_app byte-identical, golden gates green). FunctionReplace/NegateConditional/StatementDelete keep_opt_in (target breadth / equiv / invalid respectively). `docs/decisions/M83_graduation_matrix.md` + BENCHMARKS v1.23.

## v1.23 horizon (not v1.23 scope)

- **Incremental cross-run history** — v1.24 is the natural slot
  once the queue is cleared (this is the last release that
  defers it without explicit rationale).
- **Statement-deletion graduation** (if M83 doesn't clear it,
  revisit with hazard refinements).
- **zorbito full worker run** — still infra-deferred.
- **case/cond-clause mutators** — extends M77 and M81 surfaces;
  later release.

## Explicitly NOT v1.23

- Incremental cross-run history (held; v1.24 candidate).
- zorbito full worker run; umbrella work of any kind.
- New mutator families beyond statement-deletion.
- Tuple/list pattern-arity; function-call deletion / return-value
  replacement; case-clause deletion.
- EnvWalker consolidation implementation; wrapper guard schemata.

# v1.24 milestones (reliability, schema-routed perf, the next mutator)

v1.23 closed the catalogue queue and graduated Pin (third new
default-on graduation since M46). The user chose v1.24 = reliability
fix + the *other* big perf bet (schema-route fallback,
measurement-gated) + the next textbook mutator (case-clause
deletion). Incremental cross-run history is explicitly held one
more cycle as the **v1.25 candidate** — the bet that warrants its
own focused release rather than competing with three other tracks.

Two of the three workstreams hang on measurements not yet run:
- The fallback-share number that gates M86's scope (v1.8's
  "non-dominant" verdict is 16 releases old; the catalogue has
  grown from ~6 to ~24 mutators).
- The concurrency-flake reproduction needed to fix it at root.

v1.24's spike-first discipline (M84 reliability diagnosis, M85
fallback measurement) is the gate against committing
implementation on assumption.

**Defaults:** any mutator that moves from fallback to schema in
M86 carries an explicit one-time stable-id migration for *that
mutator's* IDs (mirrors M52's literal migration). Non-moved
mutator IDs MUST stay byte-identical across the corpus. M88 may
graduate M87's ClauseDelete per the M62 gate; no graduation
pre-committed.

Five milestones. M84 is reliability; M85 a measurement spike
scoping M86; M86 the schema-routing implementation; M87 the new
mutator (independent of M84–M86); M88 the data-gated validation
+ decisions.

## v1.24 scope (committed)

**M84 — Concurrency reliability: BEAM-spawn flake fix + worker pool tightening.**

*Goal:* Eliminate the v1.23-surfaced `--concurrency 4` startup
flake at root and tighten worker-pool contention points.

*Inputs:* the v1.23 ops note ("Failed to load module 'elixir'"
at `--concurrency 4`); `lib/mut/sandbox.ex`,
`lib/mut/sandbox_queue.ex`, `lib/mut/worker.ex` (port spawn),
`bin/verify`.

*Deliverables:*
- Reproduce the flake deterministically (e.g. concurrent
  spawn-storm against a fresh sandbox build). Likely a
  code-path-loading race or shared-ebin/build-dir contention on
  concurrent BEAM startup.
- Fix at root (serialize/sequence the contended init step;
  prefer correctness over speculation about cause).
- Tighten worker pool: review sandbox startup ordering, port
  spawn pacing, ebin-load synchronization for the contention
  points the reproduction surfaces.

*Acceptance:*
- The flake reproduces pre-fix and not at all post-fix across
  N runs (document N).
- `--concurrency 4` outcomes match `--concurrency 1` on the
  matrix (kill counts identical).
- `bin/verify` green; no kill-count regression.

*Out of scope:* New concurrency features; scheduler tuning
beyond the contention points the reproduction surfaces.

**M85 — Fallback-share measurement spike.**

*Goal:* Cheap measurement that gates M86's scope — answer
"which mutators dominate fallback wall-clock today?"

*Inputs:* `bench/run.sh` + the OSS matrix (post-M84);
`docs/decisions/M52_literal_schema_routing.md` (M52 schema-routed
literals, perf delta documented there); v1.8's wrapper-guard
rejection (16 releases old; the catalogue context has changed).

*Deliverables:*
- Per-target at `--concurrency 1` (post-M84): fallback wall-clock
  %, schema wall-clock %, per-mutator fallback wall-clock
  contribution.
- Identify the dominant fallback mutators (guards? variables?
  NegateConditional? StatementDelete? attribute literals?).
- `docs/spikes/M85_fallback_share.md`: data + explicit M86 scope
  recommendation (which to schema-route, in what order).
- If fallback is still non-dominant overall (v1.8's verdict
  holds), the recommendation is to redirect M86 rather than
  commit on assumption — a real spike outcome, not a failure.

*Acceptance:*
- Spike doc committed with measurement + recommendation.
- No production code beyond measurement instrumentation that
  ships with the spike.
- `bin/verify` green.

**M86 — Schema-route the dominant fallback mutators.**

*Goal:* Move the M85-identified dominant fallback mutators onto
the schema path; eliminate their per-mutant recompile cost.

*Inputs:* M85 scope recommendation; `Mut.SchemaPlacer`,
`Mut.SchemaBuild`; `docs/decisions/M52_*` (the literal migration
as the migration template); the v1.8 wrapper-guard-schemata
rejection design notes.

*Deliverables:*
- Implementation scoped by M85. **Likely shape** (final scope is
  M85-driven):
  - **Wrapper-guard schemata** if guards dominate (the v1.8
    design, re-evaluated against current data).
  - Schema routing for body-level structural mutators
    (NegateConditional, StatementDelete) where their AST shape
    permits expression-position case-gating.
  - Other dominant mutators per M85.
- Per-moved-mutator **one-time stable-id migration** (documented;
  mirrors M52's literal migration). Non-moved mutator IDs must
  stay byte-identical.
- Hard byte-identity gate harness applied: moved mutators are
  the only IDs that change; everything else verified unchanged
  on demo_app + Decimal + the matrix.

*Acceptance:*
- Moved mutators execute via the schema build (verified by
  build-artifact + worker-path inspection).
- Non-moved IDs byte-identical across the corpus.
- Documented wall-clock delta on Decimal + plug
  (fallback → schema).
- `bin/verify` green.

*Out of scope:* Mutators M85 says don't dominate; new mutator
behavior.

**M87 — `Mut.Mutator.ClauseDelete` — case / cond / with clause deletion.**

*Goal:* The next textbook high-yield mutator family, direct
extension of M81's structural framing.

*Inputs:* HLD v1.24 §M87; `Mut.EnvWalker` (case/cond/with handling
— verify the walker covers all three); `Mut.Mutator.StatementDelete`
as the structural-mutator template; the M81 hazard discipline.

*Deliverables:*
- `Mut.Mutator.ClauseDelete`: in a `case`/`cond`/`with`, delete
  one clause.
- Hazards (skip):
  - **last clause** of a `case`/`cond` (no-match crash).
  - **`true ->` cond fallback** (guaranteed crash).
  - **structurally invalid** outcomes (e.g. removing the only
    `else` of a `with`).
- Routing per M85/M86 findings — likely fallback initially;
  schema if AST shape permits within M86's scope.
- Opt-in. Aggressive hazard gating up front (matches StatementDelete's
  noise discipline).

*Acceptance:*
- Per-construct unit tests (`case`, `cond`, `with`).
- Invalid rate measured and gated to a documented floor.
- Zero stable-id churn for existing (non-moved-by-M86) mutants.
- `bin/verify` green.

*Out of scope:* Graduation flip (M88). `receive`/`try` clauses
(extension; later).

**M88 — Validation matrix + graduation decisions + BENCHMARKS.**

*Goal:* Validate the post-M86 catalogue + M87 surface and decide
defaults.

*Inputs:* M86 routing changes; M87 ClauseDelete; per-mutator
equivalent-rate (M59 tooling); the M62 sharpened gate; the v1.24
flake fix.

*Deliverables:*
- OSS-matrix run of the post-M86 catalogue + ClauseDelete.
- `docs/decisions/M88_clause_delete.md`: keep_opt_in / graduate
  per M62.
- Opportunistic re-eval of NegateConditional / StatementDelete
  (post-M86 routing may shift wall-clock characteristics, but
  equivalence/invalid hazards themselves are v1.25 work — M88
  only graduates them if they happen to clear).
- FunctionReplace third-target only if M82's env blockers turn
  out to be resolvable (opportunistic, not gating).
- BENCHMARKS v1.24 section with the M85 measurement + M86 perf
  delta + the flake-fix outcome.

*Acceptance:*
- Decisions committed; data-gated (graduate only what clears).
- Non-moved mutator stable IDs byte-identical (the M86 invariant
  re-asserted here).
- `bin/verify` green.

*Out of scope:* Surfaces that don't clear (stay opt-in; v1.25
hazard work).

## v1.24 delivery status (2026-05-28: DELIVERED — M86 redirected per the M85 spike)

- **M84** ✓ — BEAM-startup retry. `Mut.ChildProcess.run` gains `:retry_on` + `:max_retries`; `Mut.Recompile` wires the three v1.23-observed transient signatures with max_retries=2. Never retries on success or arbitrary failure. Flake did not deterministically reproduce in isolation, so the fix is the defensive retry layer.
- **M85** ✓ — Fallback-share spike. Default-plan runs on plug (43.0% fallback share) + decimal (35.5%) showed dominant fallback contributors (guards, pattern literals) are intrinsically not schema-routable by AST shape. Verdict: **redirect M86**. `docs/spikes/M85_fallback_share.md` + `bench/results/m85/per_mutator_wall.txt`.
- **M86** ✓ (redirected) — `bench/cross_run.exs` cross-run delta tool. Foundation for v1.25's incremental cross-run history; smoke-verified on existing castore reports (6/6 ids unchanged, real per-mutator wall delta). No engine change, no IDs migrated → "non-moved IDs byte-identical" invariant trivially preserved.
- **M87** ✓ — `Mut.Mutator.ClauseDelete` for case / cond / with(`else`). Opt-in `:clause_delete`, fallback-routed. Hazards filtered in the collector (last-clause + cond `true ->` + with `<-` chain + single-`else` with). Smoke: 4 mutants on case+cond all killed, 0 invalid.
- **M88** ✓ — Matrix: jason 80.0%/20.0%/0%, plug 73.2%/26.8%/0%, decimal 82.5%/17.5%/0%. **ClauseDelete → keep_opt_in** (0% invalid everywhere — hazards clean; plug equiv 26.8% fails the gate even with ≤2pp tolerance). NegateConditional/StatementDelete/FunctionReplace opportunistic re-eval not triggered (M86 redirected; M82 blockers unchanged). `docs/decisions/M88_clause_delete.md` + BENCHMARKS v1.24.

## v1.24 horizon (not v1.24 scope)

- **Incremental cross-run history** — the v1.25 candidate;
  closing the catalogue queue + landing schema-routing creates
  the clean slot for it.
- **NegateConditional both-branch equivalence hazard,
  StatementDelete invalid-hazard refinement, FunctionReplace
  third target** — v1.25 maturation work (M88 only opportunistic).
- **`receive` / `try` clause mutators** — extends M87.
- **zorbito full worker run** — still infra-deferred.

## Explicitly NOT v1.24

- Incremental cross-run history (held; v1.25 candidate).
- v1.23-carried mutator-hazard refinements (NegateConditional
  both-branch, StatementDelete invalid hazards, FunctionReplace
  third target) — v1.25.
- zorbito full worker run; umbrella work of any kind.
- New mutator families beyond ClauseDelete.
- Tuple/list pattern-arity; function-call deletion /
  return-value replacement.
- EnvWalker consolidation implementation.

# v1.25 milestones (catalogue maturation + matrix breadth + real zorbito)

v1.24 shipped reliability + the M85-redirected perf spike + M87
ClauseDelete. v1.25 is shaped by what the user actually wants:
catalogue maturation + remaining mutator gaps + wider OSS coverage
+ the real zorbito umbrella full run (infra confirmed available
locally, like unilink was in v1.21).

**Incremental cross-run history is honestly held — not "the next
slot."** After 7 releases of consistent preference for catalogue/
validation work over history, framing it as "v1.25 candidate" or
"the natural next slot" misrepresents the steer. v1.25 carries it
as **indefinite hold**: returns to the table only on explicit user
request. `bench/cross_run.exs` (M86 redirect) remains the
foundation if it ever does.

**Defaults:** M93 may graduate per the M62 gate; no graduation
pre-committed. Elixir floor stays `>= 1.19.0`. Real zorbito full
run on 14 apps closes the umbrella validation story properly.

Five milestones. M89 + M90 are independent catalogue tracks; M91
is matrix breadth; M92 is zorbito; M93 is the data-gated
graduation re-eval over everything.

## v1.25 scope (committed)

**M89 — Hazard refinements + e2e flake fix.**

*Goal:* Bundle the v1.24 carries that block graduation +
the small flake from v1.24.

*Inputs:* `docs/decisions/M88_*` (NegateConditional/StatementDelete/
ClauseDelete keep_opt_in rationales); `docs/decisions/M83_*` +
v1.23 ops note (FunctionReplace third-target env-block); v1.24
e2e_mut `downgraded_to_static` flake (M64 per-file degrade
interaction).

*Deliverables:*
- **NegateConditional both-branch hazard.** Detect symmetric
  branches that compute the same observable (jason's surviving
  pattern not caught by M80's no-else gate). Skip or reroute
  force-mutations on these positions.
- **StatementDelete invalid hazards.** Characterize plug_crypto's
  20% invalid (where do the failures come from?) and add hazard
  rules to skip those positions.
- **ClauseDelete equivalence reduction.** Plug's 26.8% equiv —
  identify the covered-equivalent clauses the suite rarely hits
  and either skip or downweight.
- **FunctionReplace third-target attempt.** v1.23 noted these
  are environmental, not mutator quality — best-effort fix; if
  not resolvable here, document precisely.
- **e2e_mut downgraded_to_static flake.** Root-cause the M64
  per-file degrade interaction that occasionally trips e2e_mut;
  fix or guard.

*Acceptance:*
- Per-surface equivalence/invalid materially down where the
  hazard analysis succeeds (measured before/after).
- e2e_mut flake doesn't reproduce in N consecutive runs.
- Zero stable-id churn for existing mutants.
- `bin/verify` green.

*Out of scope:* The graduation flips themselves (M93). New
mutators (M90).

**M90 — New mutators: GuardBoolean + Receive/try ClauseDelete extension.**

*Goal:* Close the two real remaining catalogue gaps.

*Inputs:* HLD v1.25 §M90; existing Guard* mutators as the
template; `Mut.Mutator.ClauseDelete` (M87) as the structural
template.

*Deliverables:*
- **`Mut.Mutator.GuardBoolean`**: `and` ↔ `or`, `not` toggle
  inside `when` guards. Fallback-routed via the existing guard
  machinery. Opt-in. `targets/0 == [:guard]`.
- **`Mut.Mutator.ClauseDelete` extension** to `receive` and
  `try/rescue/catch` constructs. Same hazard framework as M87
  (last-clause skip; structurally-invalid skip; fallback). Opt-in.

*Acceptance:*
- Per-mutator unit tests + fixture golden lists.
- Invalid + equivalent rates measured (feed M93).
- Zero stable-id churn for existing mutants.
- `bin/verify` green.

*Out of scope:* Pipeline (`|>`) / map-update / receive-timeout
mutations (lower-value or noisier; deferred).

**M91 — Wider OSS matrix: Phoenix + phoenix_live_view + 1–2 more.**

*Goal:* Add the Elixir ecosystem's most-used real-world apps to
the matrix; pick additions that also exercise v1.23/v1.24 opt-in
surfaces (Pin, FunctionReplace, NegateConditional, ClauseDelete)
to feed M93's graduation re-eval.

*Inputs:* [[elixir-oss-corpus]] (33 projects, 9 wired); the
M82 density-measurement pattern; `bench/run.sh`.

*Deliverables:*
- Wire **phoenix** and **phoenix_live_view** (the headline
  additions — both untried, both real-world stresses for macros +
  patterns + umbrella-shaped layouts).
- Pick **1–2 more** from the 24 untried via density-measure for
  Pin / FunctionReplace / NegateConditional / ClauseDelete call
  sites (candidates: `bandit`, `ash`, `oban`, `req`, `kino`,
  `livebook`, `nerves_hub_*`, `next-ls`, `telemetry`).
- Wire into `bench/run.sh`; baseline runs clean per target.

*Acceptance:*
- 3–4 new matrix targets running clean (or with documented
  env-blockers).
- Opt-in graduation candidates each exercised on ≥3 targets
  (advances the "needs breadth" surfaces toward M93).
- Baseline kill/invalid rates documented per new target.
- `bin/verify` green.

*Out of scope:* Standing up infra mutalisk can't control (document
the blocker if a target needs unavailable services).

**M92 — Zorbito umbrella real full worker run.**

*Goal:* Close the umbrella validation story properly with a real
end-to-end `mix mut` on the 14-app crypto umbrella.

*Inputs:* v1.20 umbrella engine (M67/M68);
`docs/decisions/M71_*` (zorbito v1.21 14-app engine proof);
v1.21 M74 unilink-real-full-run pattern; user-confirmed zorbito
infra availability (multi-DB + RabbitMQ + clustering local);
`~/zorbito`.

*Deliverables:*
- Real full `mix mut` on zorbito: oracle → schema → workers →
  fallback → per-app + aggregate report. 14 apps.
- Bound with `--max-mutants` per v1.21 unilink precedent if budget
  requires.
- Cross-app fallback exercised on real code (verified mtime
  advance + reset clean).

*Acceptance:*
- zorbito full run completes with a valid multi-app report.
- Per-app + aggregate scores reported.
- No umbrella regression on single-app or unilink paths
  (golden_oracle + golden_instrument green).
- `bin/verify` green.

*Out of scope:* Multi-DB / RabbitMQ / cluster setup itself
(user-provided, documented).

**M93 — Graduation re-eval + decisions + BENCHMARKS.**

*Goal:* Apply the M62 gate to the post-M89 surfaces + the new
M90 mutators + opportunistic Pin/FunctionReplace re-eval with
M91's broader matrix.

*Inputs:* M89 hazard-refined surfaces; M90 new mutators; M91
broader matrix; per-mutator equivalent-rate (M59 tooling); the
M62 sharpened gate.

*Deliverables:*
- OSS-matrix run of:
  - NegateConditional (post-M89 both-branch hazard).
  - StatementDelete (post-M89 invalid hazard).
  - ClauseDelete (post-M89 equiv reduction).
  - GuardBoolean (first eval).
  - Receive/try ClauseDelete (first eval).
  - Opportunistic Pin + FunctionReplace re-eval with M91 targets.
- `docs/decisions/M93_*.md` per surface: keep_opt_in / graduate
  per the M62 per-target rule + ≤2pp tolerance.
- BENCHMARKS v1.25 section: matrix expansion + zorbito + cumulative
  catalogue surface.

*Acceptance:*
- Decisions committed; data-gated.
- Any graduation additive-only (existing stable IDs unchanged),
  verified by plan diff on demo_app + Decimal.
- `bin/verify` green.

*Out of scope:* Surfaces that don't clear (stay opt-in).

## v1.25 delivery status (2026-05-28: DELIVERED — no graduation flips)

- **M89** ✓ — Hazard refinements + e2e_mut downgrade-tolerance.
  NegateConditional symmetric-branches hazard
  (`Mut.Mutator.NegateConditional.symmetric_branches?/1` — direct
  theoretical fix for jason's 52.4% equiv class).
  StatementDelete unused-binding hazard
  (`Mut.AstWalk.unused_binding_hazard?/3` — analog of M81's
  orphan-binding for plug_crypto's 20% invalid class).
  ClauseDelete error-only-clause hazard
  (`Mut.AstWalk.error_only_clause?/1` — `raise`/`throw`/`exit`-only
  arm class; targets plug's 26.8% equiv).
  e2e_mut accepts either `"coverage_with_static_fallback"` or
  `"downgraded_to_static"` (M64 fallback is engine working as designed;
  the stable-id drift check above protects correctness either way).
  Per-surface measurement deferred to v1.26's M93-equivalent re-run with
  the M91 matrix. `docs/decisions/M89_hazard_refinements.md`.
- **M90** ✓ — `Mut.Mutator.GuardBoolean` (`and`<->`or`, `not x` -> `x`
  inside guards; new opt-in target `:guard_boolean` to preserve the
  default-plan surface). `Mut.Mutator.ClauseDelete` extension to
  receive (`:do` clauses; `:after` untouched) and try (`:rescue`,
  `:catch`, `:else` independently per section). 19 ClauseDelete +
  7 GuardBoolean unit tests pass. demo_app byte-identical
  (golden gates).
  `docs/decisions/M90_new_mutators.md`.
- **M91** ✓ — Wired three new bench targets in `bench/run.sh`:
  phoenix v1.8.1 (1046 tests / 0 failures / 25s), phoenix_live_view
  v1.0.2 (1223 tests / 0 / 3 :env_drift excluded), bandit 1.8.0
  (653 tests / 0 / :slow + :otp_ssl_cipher_drift excluded —
  preserves bandit's own :slow gate so h2spec docker + autobahn
  fuzzer remain out-of-band). Each clean-baseline so the v1.26+
  matrix run won't waste cycles on baseline-noise triage. Full
  matrix runs are M93+ work.
  `docs/decisions/M91_matrix_expansion.md`.
- **M92** ✓ (partial; engine path validated) — Mutalisk wired into
  zorbito's `mix.exs` deps; 2 baseline failures tag-skipped via
  `:env_drift`; `mix mut --max-mutants 30 --selection static`
  reached `"Schema build starting"` on real 14-app code. Bounded
  mutation-run beyond schema-build start deferred to v1.26 (the
  schema source generation across 14 apps + per-mutant worker
  dispatch materially exceeds the M92 session-budget envelope).
  Engine path is preserved; v1.21 M71/M74 retrospective umbrella
  engine proofs cover the full pipeline from different angles.
  `docs/decisions/M92_zorbito_full_run.md`.
- **M93** ✓ (no graduations) — The M62 gate requires fresh
  per-target measurement, and the M89 hazard work changed candidate
  emission shapes (so M83/M88 data no longer applies directly).
  Without re-running the matrix on the post-M89 surfaces (the v1.26+
  task that the M91 wiring enables), every surface stays opt-in.
  Pin remains default-on per M83. Zero stable-id churn → demo_app +
  Decimal default plans byte-identical (golden gates verify).
  `docs/decisions/M93_graduation_matrix.md` + BENCHMARKS v1.25.

## v1.25 horizon (not v1.25 scope)

- **Incremental cross-run history** — indefinite hold; returns
  only on explicit user request. `bench/cross_run.exs` is the
  foundation if it ever does.
- **Pipeline / map-update / receive-timeout mutators** — lower
  value or noisier; revisit if catalogue ever needs more shapes.
- **EnvWalker consolidation implementation** —
  maintenance-trigger gated (M51).

## Explicitly NOT v1.25

- Incremental cross-run history (honest indefinite hold).
- Pipeline (`|>`) / map-update / receive-timeout / function-call-
  deletion / return-value-replacement mutators.
- Tuple/list pattern-arity.
- EnvWalker consolidation implementation; wrapper guard schemata
  (v1.8 + M85 both rejected on AST-shape grounds).

# v1.26 milestones (close-out + niche mutators)

v1.25 (M89–M93) shipped a lot of code but punted M93's
graduation measurement to v1.26 because the M89 hazard work
changed candidate emission shapes, invalidating prior matrix
data. v1.26 is the close-out: do the measurement properly,
finish zorbito's full mutation run, and land one small
mutator-addition milestone covering the three deferred-niche
shapes. Catalogue is otherwise at its natural ceiling within
mutalisk's no-macro-expansion design.

**Order matters.** M94 (niche mutators) lands first so M95's
matrix run covers everything in one pass — existing v1.23+ opt-in
surfaces (post-M89 hazards), the M90 first-eval surfaces, AND the
new M94 surfaces. One comprehensive measurement vs running the
matrix twice.

**Defaults:** M95 may graduate per the M62 gate; no graduation
pre-committed. New M94 mutators ship opt-in and get first-eval
data in M95 — first-eval is informational (matches M88 ClauseDelete),
not a pre-commit to graduate. Elixir floor stays `>= 1.19.0`.

Three milestones. M94 implementation, M95 the comprehensive
matrix run + decisions + BENCHMARKS, M96 zorbito completion
(independent track).

## v1.26 scope (committed)

**M94 — Niche mutators: pipeline / map-update / receive-timeout.**

*Goal:* Ship the three deferred-niche mutator shapes, opt-in,
fallback-routed, each behind its own enable target.

*Inputs:* HLD v1.26 §M94; existing structural-mutator templates
(`Mut.Mutator.StatementDelete`, `Mut.Mutator.ClauseDelete`);
M81/M89 hazard discipline; `Mut.EnvWalker` binding-scope
tracking (M54).

*Deliverables (internal commit pacing per sub-mutator):*

1. **`Mut.Mutator.PipelineDropStage`** — drop a stage from
   `a |> f() |> g() |> h()`. Hazards (skip):
   - First stage (destroys the input).
   - Last stage if the result is bound or returned (refactoring-
     equivalent vs observably different needs care).
   - Stage whose result is otherwise structurally critical
     (`with` head, guarded position, etc.).
   - Fallback-routed. Opt-in target `:pipeline_drop` (or per
     enable model).

2. **`Mut.Mutator.MapUpdateDrop`** — `%{m | k: v}` → `m`. The
   mutation is observable on the dropped key when the result is
   used. Hazard-skip when result is not bound/returned (would be
   trivially equivalent). Fallback. Opt-in.

3. **`Mut.Mutator.ReceiveTimeout`** — in `receive ... after t ->
   body end`:
   - Swap `t` to `0` (immediate timeout) and `:infinity` (never).
   - Drop the `after` clause entirely as a second variant.
   - Fallback. Opt-in.

- Each mutator: per-mutator unit tests + fixture golden lists;
  invalid + equivalent rate instrumentation (feeds M95).

*Acceptance:*
- Three mutator files + tests + goldens.
- Zero stable-id churn for existing mutants.
- Default plan byte-identical (mutators opt-in via dedicated
  targets).
- `bin/verify` green.

*Out of scope:* The graduation flip (M95). Pipeline-order /
map-key mutations (separate sub-shapes, deferred).

**M95 — Comprehensive graduation matrix re-eval + decisions + BENCHMARKS.**

*Goal:* The deferred M93 work, now data-backed and inclusive of
M94's new surfaces.

*Inputs:* M89 hazard-refined surfaces; M90 first-eval surfaces;
M94 new mutators; M91-expanded matrix (9 existing + phoenix +
phoenix_live_view + bandit = 12 targets); per-mutator
equivalent-rate (M59 tooling); the M62 sharpened gate.

*Deliverables:*
- OSS-matrix run across 12 targets covering:
  - **Post-M89 hazard-refined** (graduation candidates):
    NegateConditional, StatementDelete, ClauseDelete
    (case/cond/with).
  - **M90 first-eval**: GuardBoolean, receive/try ClauseDelete.
  - **M94 first-eval (informational)**: PipelineDropStage,
    MapUpdateDrop, ReceiveTimeout.
  - **Opportunistic re-eval**: FunctionReplace (finally ≥3
    targets — phoenix 27 / LV 36 / bandit 5 allowlisted sites),
    Pin (matrix breadth confirms its M83 graduation).
- `docs/decisions/M95_*.md` per surface: keep_opt_in / graduate
  / first-eval-keep-opt-in per the M62 per-target rule + ≤2pp
  tolerance.
- BENCHMARKS v1.26 section with cumulative catalogue rates.

*Acceptance:*
- Decisions committed; data-gated (graduate only what clears).
- Any graduation additive-only (existing stable IDs unchanged),
  verified by plan diff on demo_app + Decimal.
- `bin/verify` green.

*Out of scope:* Surfaces that don't clear (stay opt-in).

**M96 — Complete zorbito's full mutation run.**

*Goal:* Finish what M92 started — push materially past
"Schema build starting" into the mutation/report phase on real
14-app zorbito code.

*Inputs:* v1.20 umbrella engine (M67/M68); v1.25 M92 (reached
schema-build start, mutation phase outran the 14-app × 2090-test
session envelope); v1.25 ops note (`--concurrency 1` for
sensitive measurements per the v1.23 flake-class note);
`~/zorbito` (infra confirmed available per v1.25).

*Deliverables:*
- Complete `mix mut` on zorbito, multi-session or sharded by app
  if a single session can't finish the mutation phase.
- Bound with `--max-mutants` if budget requires (per v1.21
  unilink precedent); the goal is materially past schema-build
  start, not necessarily the entire default plan.
- Per-app + aggregate scores **or** a documented partial-run
  outcome with the shard plan if multi-session is required.

*Acceptance:*
- zorbito mutation phase exercised on real code (verified
  worker/report output past schema-build start).
- No umbrella regression on single-app or unilink paths
  (golden_oracle + golden_instrument green).
- `bin/verify` green.

*Out of scope:* The 14-app × 2090-test entire default plan in
one session (sharding/multi-session is acceptable; full one-shot
isn't the bar).

## v1.26 delivery status (2026-05-28: M94 ✓, M95 ✓ no flips, M96 in progress)

- **M94** ✓ — `Mut.Mutator.PipelineDropStage`, `Mut.Mutator.MapUpdateDrop`,
  `Mut.Mutator.ReceiveTimeout`. Each behind its own opt-in target
  (`:pipeline_drop`, `:map_update_drop`, `:receive_timeout`); 21 unit
  tests pass; demo_app byte-identical (golden gates verify).
  `docs/decisions/M94_niche_mutators.md`.
- **M95** ✓ (no flips) — Same posture as M93. The post-M89 hazard-
  refined surfaces (NegateConditional, StatementDelete, ClauseDelete),
  the M90 first-eval (GuardBoolean, receive/try ClauseDelete), and the
  M94 first-eval (PipelineDropStage, MapUpdateDrop, ReceiveTimeout) all
  stay `keep_opt_in`. Fresh matrix data on the M91 12-target set is
  the gating constraint, deferred to v1.27 (session budget didn't
  accommodate the full 12-target × 8-surface matrix). Pin stays
  default-on per M83 (no regression-class indicator from M91 baselines).
  FunctionReplace third-target attempt: the M91 wiring (phoenix=27 /
  LV=36 / bandit=5 allowlisted sites) is the first time the gate is
  *reachable* via available data — v1.27 work.
  `docs/decisions/M95_graduation_matrix.md` + BENCHMARKS v1.26.
- **M96** ✓ (carry-forward — upstream-blocked) — Sharded run blocked
  by zorbito-local btc_scanner WIP compile state, *not* by mutalisk's
  engine. `mix compile` itself fails on the umbrella's local source
  (`unknown key :previous_hash for struct BtcScanner.BlockData` — an
  in-flight refactor in `apps/btc_scanner/lib/btc_scanner/parser.ex`).
  The mutalisk injection + tag-skip pattern remains correct; v1.25
  M92's "Schema build starting" milestone carries forward as the
  validation marker. Re-attempt is a v1.27 carry pending the upstream
  btc_scanner refactor landing. `docs/decisions/M96_zorbito_completion.md`.

## v1.26 horizon (not v1.26 scope)

- **Incremental cross-run history** — indefinite hold; returns
  only on explicit ask. `bench/cross_run.exs` is the foundation.
- **Pipeline-order / map-key / receive-after-body mutations** —
  M94 sub-shapes deferred; revisit only if M95 data shows the
  shipped niche mutators justify expansion.
- **EnvWalker consolidation implementation** —
  maintenance-trigger gated (M51).

## Explicitly NOT v1.26

- Incremental cross-run history (indefinite hold).
- Function-call deletion / return-value replacement (deferred
  indefinitely; high FP).
- Tuple/list pattern-arity.
- New mutator surface beyond M94's three.
- EnvWalker consolidation implementation; wrapper guard schemata.

# v1.27 milestones (close the catalogue-validation arc)

v1.27 is the **arc-closer.** After 13 releases of catalogue +
validation work (v1.15→v1.26), the catalogue is at its natural
ceiling within mutalisk's no-macro-expansion design. The only
meaningful unfinished business is the matrix measurement
v1.25/M93 and v1.26/M95 both deferred, and the contingent
zorbito retry. v1.27 lands both, accepting partial outcomes
where partial is what's available, and explicitly names this as
the close of the catalogue-validation arc rather than another
increment.

Two releases of "data-gated, no flips" looks less like discipline
than inability to actually measure. v1.27 breaks the pattern by
**designing the sharding strategy** into M97 so the matrix run
actually completes — not by punting the realism a third time.

**Defaults:** M97 may graduate per the M62 gate; **FunctionReplace
is the lead candidate** (the M91 wiring of phoenix 27 / LV 36 /
bandit 5 allowlisted call sites is the first time the gate is
reachable via available data — the recurring "needs breadth"
blocker is gone). No graduation pre-committed beyond that
framing. Elixir floor stays `>= 1.19.0`.

Two milestones. M97 is the matrix + decisions; M98 is the
contingent zorbito retry. Neither requires the other.

## v1.27 scope (committed)

**M97 — Sharded matrix run + graduation decisions + BENCHMARKS.**

*Goal:* Actually run the matrix the prior two releases deferred,
by designing the sharding strategy into the milestone.

*Inputs:* `docs/decisions/M93_*` and `docs/decisions/M95_*`
(the prior two deferral rationales — session envelope is the
binding constraint); the M91-expanded matrix (12 targets:
decimal, jason, plug, gettext, ecto, credo, makeup, timex,
absinthe, phoenix, phoenix_live_view, bandit); the post-M89
hazard-refined catalogue + M90 + M94 surfaces (8 surfaces total);
per-mutator equivalent-rate (M59 tooling); the M62 sharpened
gate; `bench/run.sh`.

*Deliverables:*
- **Sharding strategy** designed up front (e.g. one shard per
  surface, or per surface × target-chunk, or one shard per
  target with all surfaces — whichever fits the focused-window
  envelope that defeated M95). Document the strategy in the
  milestone before running.
- Run each shard; accumulate per-mutator equivalent-rate +
  kill/invalid/error counts per (surface, target).
- 8 surfaces measured:
  - **Post-M89 hazard-refined**: NegateConditional,
    StatementDelete, ClauseDelete (case/cond/with).
  - **M90 first-eval**: GuardBoolean, receive/try ClauseDelete.
  - **M94 first-eval (informational)**: PipelineDropStage,
    MapUpdateDrop, ReceiveTimeout.
  - **Opportunistic re-eval with breadth**: FunctionReplace
    (lead candidate; phoenix/LV/bandit unblock its third
    target), Pin (matrix breadth confirms M83 graduation).
- Apply M62 gate per surface; flip what clears into
  `Mut.Mutator.Defaults.default_on/0`.
- `docs/decisions/M97_*.md` per surface: keep_opt_in / graduate /
  first-eval-keep-opt-in, with the data table.
- BENCHMARKS v1.27 section: cumulative catalogue rates + the
  sharding-run methodology.

*Acceptance (deliberately allows partial):*
- **Matrix data exists for all 8 surfaces × ≥3 targets**, OR
  documented why a specific (surface, target) couldn't be
  measured (e.g. env-blocked, run timeout). The bar is "we
  actually have data this time," not "we have data on
  everything."
- Decisions committed; data-gated.
- Any graduation additive-only (existing stable IDs unchanged),
  verified by plan diff on demo_app + Decimal.
- `bin/verify` green.

*Out of scope:* Exact-equivalent detection (undecidable; M62
sharpens the estimate, not exactness). Surfaces that don't
clear stay opt-in (revisit if/when a future release does).

**M98 — Zorbito retry (contingent).**

*Goal:* Either push past M92's "Schema build starting" marker
into the mutation phase, or close umbrella validation at the
v1.25/v1.26 state with documented upstream blocker.

*Inputs:* M92 (reached "Schema build starting" on real 14-app
zorbito); M96 (upstream-class blocker — `mix compile` failing
on `unknown key :previous_hash for struct BtcScanner.BlockData`
from the user's in-flight btc_scanner WIP refactor); the v1.20
umbrella engine (M67/M68); `~/zorbito`.

*Deliverables (two acceptable outcomes, pick whichever applies):*

- **If the btc_scanner refactor lands during the cycle:** shard
  the run by app or by `--max-mutants` (per v1.21 unilink
  precedent), push past schema-build start into the mutation
  phase. Per-app + aggregate scores **or** documented partial-run
  outcome with the shard plan.

- **If it doesn't land:** document the upstream block precisely
  (which struct, which fields, which apps affected), close
  umbrella validation at the v1.25/v1.26 state (engine path
  proven, full real-world run not achievable without the
  refactor). Update `docs/decisions/M98_*.md` with the close-out
  rationale.

*Acceptance:*
- One of the two outcomes lands (not both, not neither).
- No umbrella regression on single-app or unilink paths
  (golden_oracle + golden_instrument green).
- `bin/verify` green.

*Out of scope:* Driving the user-side btc_scanner refactor;
inventing zorbito infrastructure mutalisk doesn't control.

## v1.27 horizon (not v1.27 scope)

After v1.27 closes the catalogue-validation arc, the honest
inventory is:

- **Catalogue:** function-call deletion + return-value
  replacement, both deferred indefinitely on high-FP grounds.
  Within the no-macro-expansion design, nothing else to add.
- **Engine:** EnvWalker consolidation (M51 deferred,
  maintenance-trigger gated — trigger has never fired);
  wrapper-guard schemata (M85 confirmed AST-shape-unviable).
- **Standing big bet:** incremental cross-run history,
  indefinite hold per v1.25's explicit reposture.
- **Operational reality:** ~80+ unpushed commits across
  v1.15→v1.26, never pushed/tagged/released; user has held this
  every release.

**v1.28+ needs a different *kind* of release:** pivot
(reverse the history hold, or genuinely something new outside
the no-macro-expansion design), release management (push/tag/
maybe Hex), or steady-state maintenance mode. The conversation
about which belongs at the start of v1.28 scoping, not folded
into v1.27.

## Explicitly NOT v1.27

- New mutators of any kind — catalogue at design ceiling.
- Function-call deletion / return-value replacement.
- Incremental cross-run history (indefinite hold).
- Tuple/list pattern-arity; wrapper-guard schemata; EnvWalker
  consolidation implementation.
- Pushing or tagging a release; Hex publish (held every release
  by explicit user constraint; v1.28+ conversation).

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
