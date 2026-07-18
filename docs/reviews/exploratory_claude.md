# Mutalisk Exploratory Testing Log (Claude)

Tester: Claude (Opus 4.8). Goal: exercise the public API / CLI across a range of
real projects (fresh lib, Phoenix, umbrella, OSS clones), verify results and
findings, fix usability issues as found. Focus: usability, not nits or
deliberately-wrong option combinations.

Environment: Elixir 1.20.2 / OTP 28, macOS (darwin 25.5.0).
Mutalisk wired into targets as `{:mutalisk, path: <repo>, only: [:test], runtime: false}`.

Legend: [OK] verified good · [ISSUE] problem found · [FIXED] fixed in this session

================================================================================
## Project A: fresh `mix new calc` library (boundary-heavy arithmetic)
================================================================================

[OK] Happy path `MIX_ENV=test mix mut`:
  - deps.get + compile clean, run completed in ~11s.
  - 26 mutants, score 18/22 = 81.8%. Survivors are genuine boundary gaps
    (clamp `<=`, discount guard `>=`/`<=`), verified correct by inspection.
  - coverage_with_static_fallback default: schema 11/12, fallback 7/10.
  - Terminal report is detailed and readable (phases, selection, concurrency).

[OK] `--fail-at 90` exits 1 with clear message
  "[mutalisk] mutation score 81.8% below --fail-at 90.0%; failing". Exit code 1.

[OK] `--reporters terminal,html` writes stryker.report.html (self-contained) +
  stryker.report.json (Stryker schemaVersion 2, valid JSON, files keyed by path).
[OK] `--selection static` and `--selection coverage_with_static_fallback` both work.
[OK] `--max-mutants 3` caps to a stable-id sample (ran 2 scorable). `--debug-plan`
  writes plan.debug.json and exits 0 without running. `--files "lib/calc.ex"` scopes.
[OK] `--files` with a no-match glob: clear message
  "[mutalisk] --files matched no source files: ..." + guidance, then fails --fail-at
  (no scorable mutants). Good.

--------------------------------------------------------------------------------
[ISSUE → FIXED] CamelCase mutator names from the report are rejected by --mutators
--------------------------------------------------------------------------------
  Repro: run `mix mut`, see report lines like
    "[3/26] killed lib/calc.ex:5:24  Arithmetic  replace + with -".
  Naturally copy that name: `mix mut --mutators Arithmetic` →
    "** (Mix) unknown mutator "Arithmetic"; known: arithmetic, comparison_boundary, ..."
  The reports DISPLAY mutators in CamelCase (module short name) but `--mutators`
  only accepted the snake_case keys. A user copying a name straight from the
  report output hits a hard error — a real usability trap.

  Root cause: two layers keyed on snake_case only — parse-time validation
  (`validate_mutators/1` vs `@known_mutators`) and `resolve_mutators/1`
  (`mutator_mapping/0` lookup). Neither tried the CamelCase form.

  Fix (lib/mut/cli.ex): both layers now fall back to `Macro.underscore(name)`
  before failing, so `Arithmetic`/`ComparisonBoundary`/`GuardComparisonBoundary`
  (and aggregate `GuardComparison`, `Comparison`) all resolve. Verified all 30
  display names underscore cleanly to their mapping keys. Invalid names
  ("Nope"/"arithmetik") still rejected with the same message. Regression test
  added in test/mut/cli_test.exs ("accepts CamelCase mutator names as shown in
  reports"). e2e: `mix mut --mutators Arithmetic,ComparisonBoundary` now runs.

[OK] `.mutalisk.exs` config file (selection/fail_at/mutators) honored. CLI override
  works. `@mutalisk_ignore true` in a module → no scorable mutants produced.

================================================================================
## Project B: OSS `decimal` (arbitrary-precision arithmetic, stream_data tests)
================================================================================
[OK] path-dep install, deps.get, compile, run all clean. `--max-mutants 40`
  produced 37 scorable mutants, score 30/37 = 81.1% in ~39s.
[OK] Survivors verified genuine by inspection, e.g.:
  - lib/decimal.ex:715:55 `exp1 - exp2` (−→+) inside the `coef1 == 0` branch —
    untested boundary.
  - lib/decimal.ex:432:59 `compare(%Decimal{coef:0},%Decimal{sign:-1}) -> :gt`
    (:gt→:eq) — that specific clause unguarded.
  Large Skipped count (unsupported_dispatch 1057, no_applicable_mutator 457) is
  expected — those constructs have no safe mutation. No crashes, no false errors.

================================================================================
## Project C: fresh `mix phx.new shopweb --no-ecto` (+ a Pricing context)
================================================================================
[OK] Install/compile/run all clean on a real Phoenix 1.8.5 app. Full run mutated
  app + web modules; score 20/30 = 66.7% (low because generated core_components/
  endpoint/application scaffolding is untested by default — expected).
[OK] Survivors verified genuine, e.g.:
  - lib/shopweb/pricing.ex:16:59 `apply_discount(_, pct) when pct <= 100`
    (<=→<) — real untested guard boundary in my own code.
  - core_components Boolean/Pin/GuardTypeTest survivors — untested scaffolding.

--------------------------------------------------------------------------------
[ISSUE → FIXED] Guards on `defmacro`/`defmacrop` heads were mutated → CompileError noise
--------------------------------------------------------------------------------
  Repro: `mix mut` on the stock Phoenix app reported
    "[29/31] error  lib/shopweb_web.ex:111:34  GuardTypeTest  replace is_atom with is_nil"
    "Errored mutants: ... == Compilation error in file .../error_json_test.exs =="
    "Errors: 1"
  shopweb_web.ex:111 is `defmacro __using__(which) when is_atom(which)`. Guard
  mutators targeted that macro-head guard. Because `__using__` runs at COMPILE
  time and is invoked by every `use ShopwebWeb, :x`, mutating `is_atom`→`is_nil`
  changed macro expansion and broke compilation of test modules — surfacing as a
  scary "Errors: 1 / Compilation error". The README states macro bodies are not
  mutated, and the schema engine already refuses defmacro bodies
  (`refused_body_context?/1`), but the FALLBACK guard-candidate collector
  (`Mut.AstWalk.guard_candidates/2`) had no such exclusion.

  Why it matters: `__using__/1` (and other macro-head guards) are ubiquitous in
  Phoenix/Ecto/library projects. Every one would emit a guaranteed-CompileError
  mutant — wasted worker time and an alarming "Errors:" count that looks like a
  tool bug to users. (The score itself was unaffected — errors are excluded —
  but the noise undermines trust.)

  Fix (lib/mut/ast_walk.ex): `maybe_guard_candidates/3` now skips any `when`
  guard whose AST path contains a `defmacro`/`defmacrop` step
  (`in_macro_def_path?/1`), matching the documented limitation and the existing
  body-candidate behaviour. Regular function/case/with guards are unaffected.
  Regression test added in test/mut/ast_walk_guard_candidates_test.exs. Re-run
  on Phoenix: "Errors: 0", same score, no compile-error mutant.

================================================================================
## Project D: umbrella `mix new bookstore --umbrella` (catalog + orders apps)
================================================================================
[OK] Install at umbrella root (deps in root mix.exs). deps.get/compile/run clean.
  Mutated BOTH apps with correct `apps/catalog/lib/...` & `apps/orders/lib/...`
  paths. Score 14/18 = 77.8%. Survivors genuine (e.g. orders.ex needs_signature?
  `> 20_000` untested; catalog price_with_tax `rate >= 0` guard boundary).

--------------------------------------------------------------------------------
[ISSUE → FIXED] Comparisons inside `cond` clause heads were dropped as `invalid`
  (silently HIDING real survivors) — correctness bug, reproduced across calc,
  decimal, and the umbrella.
--------------------------------------------------------------------------------
  Symptom: `mix mut` reported comparison mutants on `cond` clause conditions as
  "invalid" with statusReason `missing_source_span`. Isolated minimal repro:
    def via_if(n),   do: if n < 10, ...      # SCORED (schema)
    def via_plain(n), do: n < 10              # SCORED (schema)
    cond do n < 10 -> ...                     # INVALID (dropped!)
  Only the `cond` clause-head comparison failed; `if`/plain worked.

  Why it matters (severity: HIGH): `invalid` mutants are EXCLUDED from the score.
  A `cond` boundary that no test pins should show as a SURVIVOR (a test gap). By
  silently dropping it, the tool hid the gap and inflated the score — the worst
  failure mode for a mutation tester (false confidence). `cond` is extremely
  common in idiomatic Elixir, so this hit real code (decimal, my umbrella).

  Root cause:
  - Dispatch candidates (comparisons, calls) are built with `span_fallback?:
    false` and so carry NO byte span (`from_meta` returns nil for operators —
    they have no end/closing metadata). That's fine for the SCHEMA engine, which
    addresses mutants by AST path.
  - The schema placer REFUSES certain contexts (incl. `cond` clause heads) and
    `Mut.SchemaBuild.reroute_refused/2` moves those mutants to the FALLBACK
    engine — which splices source bytes and therefore REQUIRES a span. The
    reroute kept the nil span, so `Mut.FallbackPatch.render/2` returned
    `{:error, :missing_source_span}` → status `:invalid`. (This also silently
    broke every other refused→fallback dispatch reroute, e.g. macro-body calls.)

  Fix:
  - lib/mut/ast_walk.ex: new public `fallback_span/3` recomputes a byte span for
    a node by text-searching its rendered form on its source line (reusing the
    existing `source_text_span/3`).
  - lib/mut/schema_build.ex: `reroute_refused/3` now takes the original sources
    and, for each rerouted mutant lacking a span, recovers one via
    `fallback_span/3` (setting start_byte/end_byte/span/original_source). Mutants
    whose span still can't be located are DROPPED (not emitted as bogus
    `invalid`).
  Verified: cond comparisons now score correctly — survive when the boundary is
  untested, and are KILLED when a boundary test exists (mutation applies cleanly,
  source not corrupted). `Invalid: 0` on the repro. Full suite 648 → green.
  Regression tests: test/mut/ast_walk_test.exs ("fallback_span/3 ..." describe).


  *** ROOT-CAUSE FIX (supersedes the reroute-only patch above) ***
  Deeper investigation found the schema placer's `clause_head_pattern_path?/1`
  (lib/mut/schema_placer.ex) refused ANY `->` clause head as a pattern. But
  `cond` clause heads are boolean EXPRESSIONS (body position), schema-
  instrumentable just like an `if` condition — `Mut.AstWalk` already knew this
  (`pattern_clause_head?/1` excludes cond), but the placer used the naive check.
  So cond comparisons were needlessly refused → rerouted to fallback → (no span)
  dropped/invalid.
  Proper fix: ported the cond-aware `pattern_clause_head?/1` logic into the
  schema placer (case/fn/with/try/receive heads stay refused; cond heads
  instrument). Now cond comparisons/literals go through the SCHEMA engine — no
  byte span needed, robust for ALL literal forms incl. `10_000` underscores
  (which broke the text-search span recovery: `Macro.to_string` renders
  `10_000` as `10000`, so the fallback path could never have located them).
  Impact on the umbrella: discount_tier's `cond` `>=` mutants went from 4×
  invalid (hidden) to 4× KILLED. Score corrected 14/18=77.8% (CI fail) →
  18/22=81.8% (CI pass) — the bug had distorted the score in BOTH directions.
  The reroute span-recovery (above) is kept as a non-destructive safety net for
  genuinely fallback-only refused contexts (e.g. dispatch in macro bodies);
  unrecoverable cases now stay `invalid` (visible), never silently dropped.
  Regression tests: schema_placer_test.exs ("cond clause head is instrumented",
  "case clause head dispatch is still refused"). Full suite incl. golden: 671 green.

================================================================================
## Project E: OSS `jason` (JSON encoder/decoder — binary/bitstring parsing)
================================================================================
[OK] Install/compile/run clean. lib/decoder.ex: 41/50 = 82%, Errors 0. Survivors
  genuine (arithmetic on byte-offset math, unchecked boundaries).
[OK] jason.ex is a thin facade (mostly unsupported_dispatch) — handled gracefully.

--------------------------------------------------------------------------------
[ISSUE → FIXED] Guards/comparisons with NON-DECIMAL literal operands dropped as
  `invalid` (missing_source_span) — hid real survivors. Pre-existing.
--------------------------------------------------------------------------------
  Found on jason decoder: 3 guard mutants invalid with `missing_source_span`:
    lib/decoder.ex:403/405  `char <= 0x7FF` / `char <= 0xFFFF`  (hex literals)
    lib/decoder.ex:565      `first <= 0xFF`
  Root cause: the fallback span computation (`Mut.AstWalk.source_text_span/3`,
  used for ALL guard mutants and rerouted dispatch) locates the expression by
  searching the SOURCE LINE for `Macro.to_string(node)`. But Macro.to_string
  NORMALISES operand literals — `0x7FF`→`2047`, `10_000`→`10000`, `?a`→`97` — so
  the rendered text no longer matches the source bytes, the search misses, and
  the mutant is dropped as `missing_source_span` → `invalid` (excluded from the
  score, hiding the gap). Affects hex/octal/binary/underscored ints and char
  literals in guards/comparisons — common in parsers, binary/UTF-8 code, crypto.

  Fix (operator-anchored span + replacement):
  - lib/mut/ast_walk.ex: when the whole-expression search fails, fall back to
    `operator_token_span/3` — the node meta column points at the operator, whose
    text is immune to operand formatting; emit a span covering just the operator
    token (self-validated against the source).
  - lib/mut/fallback_patch.ex: `operator_only_replacement/2` detects a pure
    operator swap (same operands) whose span equals the original operator and
    substitutes ONLY the new operator — so `0x7FF` is preserved verbatim
    (`char <= 0x7FF` → `char < 0x7FF`), not rewritten to `2047`.
  This is backward-compatible: decimal-operand guards still match the whole
  expression (operator fallback never triggers; whole-node replacement as before).
  Verified: jason decoder Invalid 3 → 0; the hex guards now score (403 killed,
  405 survived) with the literal intact. Regression tests:
  fallback_patch_test.exs ("operator-only span ...") +
  ast_walk_guard_candidates_test.exs ("operator-token span ...").

================================================================================
## Project F: guarded_struct (OSS, macro/DSL + guard heavy, 4.7k LOC, 146 tests)
================================================================================
Setup: path dep added to mix.exs; baseline green (146 tests, 1.3s).
Full run: score 63.1%, 408 executed — but Errors: 96 and ENTIRE fallback
mutator categories at 0 killed (guard_type_test 0/57, guard_comparison_negation
0/19, pin_removal 0/2, unary_not_removal 0/2). Fallback wall-clock 0.0% —
~80ms/mutant, too fast to have compiled anything. Scoped re-run with
stryker-json exposed the shared error.

ISSUE 5 (correctness, HIGH): Elixir 1.21-dev writes Mix manifest v36; every
  fallback mutant errors → fallback engine silently dead. Pre-existing.
--------------------------------------------------------------------------------
  All 96 errors were the same: {ArgumentError, "unsupported Mix Elixir manifest
  shape/version 36; Mut.MixManifest supports manifest versions [29, 34, 35]"}.
  The local Elixir (1.21.0-dev) bumped the compile.elixir manifest version
  35 → 36. `Mut.Worker.run_fallback/4` reads the manifest per mutant to compute
  recompile dependents; the version pin made EVERY fallback mutant error at
  ~80ms. Consequences:
  - The whole fallback engine (all guard mutants, pin/unary_not removal,
    rerouted dispatch) produces zero verdicts on Elixir ≥ 1.21-dev.
  - The terminal breakdown shows "guard_type_test: 0/57 killed" — reads as
    catastrophically weak tests when in fact NOTHING ran. Errors: 96 is
    visible, but each carries only a truncated per-mutant message.
  - Mutalisk's own test suite fails on such Elixir versions
    (mix_manifest_test "read parses the real demo_app schema manifest").

  Fix:
  - lib/mut/mix_manifest.ex: accept version 36 after probing a real v36
    manifest — shape is byte-identical to v35 (11-tuple outer, 6-tuple
    `{:module, ...}` records, 12-tuple `{:source, ...}` records).
  - lib/mix/tasks/mut.ex: preflight the manifest ONCE before the fallback
    worker phase; on failure print a single loud diagnostic ("fallback engine
    cannot read the Mix compiler manifest ... every fallback mutant will be
    reported as an error; this usually means the Elixir version is newer than
    mutalisk supports") instead of leaving N cryptic per-mutant errors as the
    only signal. Mutants still run/error so they stay visible in reports.
  - test/mut/mix_manifest_test.exs updated to the new version list (and the
    real-manifest test now passes again under 1.21-dev).
  Verified: scoped re-run on lib/derive/validation_derive.ex:
    before: Fallback 0/0 detected, Errors 27, guard_type_test 0/26 killed
    after:  Fallback 12/27 detected (44.4%), Errors 0, guard_type_test 12/26
            killed — real verdicts; remaining survivors are genuine test gaps
            (e.g. is_float→is_number inside `is_integer(x) or is_float(x)`).
  Also confirmed: selection auto-downgraded to static on this macro-heavy
  project (mode printed as downgraded_to_static) — matches the documented
  fast path for macro-heavy apps; no action needed.
  Mutalisk suite after fix: 674 passed (all tags incl. golden/integration/e2e).

================================================================================
## API surface verified
================================================================================
[OK] Flags: --files (glob + no-match), --mutators (snake + CamelCase), --enable
  implicit, --fail-at (exit codes), --reporters (terminal/stryker-json/html/
  github-actions), --selection (static / coverage_with_static_fallback),
  --max-mutants, --debug-plan, --incremental (history reuse + re-run on edit),
  --help. Config: .mutalisk.exs + CLI override. Source: @mutalisk_ignore.
[OK] --since: alone → clear "no effect without --incremental" warning; with
  --incremental in a non-git dir → warns and falls back to digest-only reuse
  (all 26 verdicts still reused); with git + edited file → changed-file mutants
  conservatively re-executed. --output-path honored by stryker-json (and
  warns when inert with terminal-only reporting).
[OK] --keep-work-copy retains + prints both work copies (schema and
  oracle/baseline; contents verified). --test-timeout-ms and --concurrency
  reflected in the run summary (3000 ms / 2 workers). Every documented CLI
  flag has now been exercised.
[OK] Project shapes: fresh lib, Phoenix (--no-ecto), 2-app umbrella, OSS decimal/
  jason, OSS guarded_struct (macro/DSL heavy). Reports valid (Stryker
  schemaVersion 2). No crashes; errors/invalids only where legitimately
  unmappable.

## Summary of fixes this session
  1. --mutators accepts CamelCase names shown in reports (cli.ex)
  2. defmacro/defmacrop head guards no longer mutated (compile-error noise) (ast_walk.ex)
  3. cond clause-head dispatch/literals schema-instrumented, not hidden (schema_placer.ex
     + schema_build.ex reroute span recovery as safety net)
  4. operator-anchored fallback span/replacement: guards/comparisons with hex/
     underscore/char literals now score, literals preserved (ast_walk.ex + fallback_patch.ex)
  5. Mix manifest v36 (Elixir 1.21-dev) supported — fallback engine was 100%
     dead (every fallback mutant errored); plus a one-shot preflight diagnostic
     when the manifest is unreadable (mix_manifest.ex + mix/tasks/mut.ex)
  All five are correctness/usability issues that HID real mutants or produced
  scary noise. Full suite (all tags incl. golden/integration/e2e): 674 passing.

Current audit (2026-07-18): all five fixes remain present with regression
coverage. The release harness, warning-free docs build, Hex package build, and
an unpacked-package consumer mutation smoke test are green on Elixir 1.20.2 /
OTP 28.
