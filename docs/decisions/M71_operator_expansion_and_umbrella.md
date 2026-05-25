# M71 — operator-expansion default policy + umbrella verdict (v1.20)

**Date:** 2026-05-25

## Umbrella support — VERDICT: validated, ship enabled (automatic on `apps_path`)

Umbrella handling is automatic: the engine detects an `apps_path` project
(`Mut.Umbrella`) and applies the per-app overlay. No flag required.

Validated end-to-end on `~/unilink` (5 apps: backoffice, unilink,
unilink_backend, unilink_background, unilink_tracking):

| phase | result |
|---|---|
| oracle build | 89 518 dispatch sites, app-prefixed across all 5 apps, no `lib/` collisions |
| plan | 1031 default-plan mutants spanning all 5 apps (772 schema / 259 fallback) |
| schema build | instruments `apps/<app>/lib`, compiles the instrumented umbrella, per-app ebin snapshot |
| cross-app fallback | hub mutant (`Unilink.Model.PlatformClient`) → 93 compile/struct/export dependents across **all 5 apps**; recompiled in one pass, beams routed to each app's own ebin (verified mtime advance in `unilink_backend`); source reset restores the patched hub file |

The **worker + report** phase was validated on a self-contained 2-app
umbrella (no external infra): full `mix mut` completes with a valid
report spanning both apps — `8/9 killed, 0 invalid, 0 errors`. A full
`mix mut` on unilink itself is gated on its Postgres/RabbitMQ test infra
(out of scope here); the engine path is fully exercised by the above.

### Umbrella bugs found & fixed (the M66 spike's "root untouched" model was wrong)

- **Root must be wrapped too.** Mix runs `deps.loadpaths` once at the
  umbrella root then `compile.all` per child (no per-child loadpaths), so
  `:mutalisk` must be on the *root's* deps or `compile.mut_oracle` is
  undiscoverable in every child.
- **Distinct per-app wrapper module names** (else they redefine
  `Mutalisk.WrappedMixProject` in one BEAM, corrupting `Mix.Project.get!()`).
- **Idempotent `:mut_oracle` compiler** (runs once per child app in one
  BEAM — register the tracer once, start the JSONL Writer once).
- **Sites keyed to `MUTALISK_PROJECT_ROOT`** not the compiler cwd (Mix
  changes cwd per child app → bare `lib/...` collisions otherwise).
- **Single-pass `ParallelCompiler.compile`** for cross-app recompile with
  `:each_module` beam routing — per-app `compile_to_path` passes lose
  cross-app compile ordering ("no such import").
- **Multi-suite result aggregation** — umbrella `mix test` emits one
  `suite_finished` per app; the worker now sums them (a kill in a later
  app was mis-reported as an error).
- **File discovery** spans `apps/*/lib` (CLI default `files` → `nil` →
  umbrella-aware `discover_files`).

Single-app path is byte-identical throughout (golden_oracle +
golden_instrument green; demo_app + Decimal stable-ids unchanged).

## Operator-expansion mutators (M69) — DECISION: keep_opt_in

ConcatOperator / BitwiseOperator / Membership stay opt-in
(`--mutators` / `--enable`). They are functionally correct but the
data does not clear the M62 graduation gate (<20% equivalent on every
target) and shows real noise:

| target | mutator | killed | survived | invalid (compile) | error (runtime/abort) |
|---|---|---:|---:|---:|---:|
| synthetic umbrella | Concat/Member/Bitwise | 6 | 1 | 0 | 0 |
| plug_crypto | BitwiseOperator | 0 | 2 | 0 | 0 |
| jason | ConcatOperator | 1 | 2 | 2 | 4 |
| jason | Membership | 0 | 1 | 0 | 0 |

Findings:
- **ConcatOperator is noisy** on real list/binary code: `++`→`--` in
  jason's encoder produced 2 compile errors (refused/macro positions
  rerouted to fallback) and 4 suite-aborting runtime crashes (≈67%
  non-productive of 9). Needs hazard rules akin to the literal mutators
  before it can graduate.
- **BitwiseOperator** produces input-dependent pseudo-equivalents
  (`bor`/`bxor` coincide for the test inputs; plug_crypto's 2 survived) —
  low invalid but weak kill signal.
- **Membership** is the cleanest (0 invalid) but the sample is thin.

This matches the conservative graduation history (M55 variable, M60
surfaces both kept opt-in). Graduation revisited in v1.21 with the full
OSS matrix + per-mutator equivalent-rate and ConcatOperator hazard gating.

## M70 (pattern-shape mutators) — CUT to v1.21

Per the plan's release-valve rule ("cut to v1.21 if umbrella runs long;
M71 does not depend on it landing"). The umbrella track (M66–M68) ran
long with deep debugging (six distinct umbrella correctness bugs above),
and pattern-shape mutators are the highest-noise/highest-invalid surface
in v1.20, requiring new binding-scope-aware pattern walking. Shipping the
validated umbrella + operator-expansion surface as v1.20 and deferring the
noisiest surface is the responsible call. v1.21 picks up M70 alongside
zorbito (the 14-app umbrella) and the operator-mutator graduation matrix.
