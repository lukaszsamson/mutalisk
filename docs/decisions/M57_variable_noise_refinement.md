# M57 — variable-mutator noise refinement + identifier-classification hardening

**Date:** 2026-05-25
**Goal:** cut the v1.17 variable-mutator error tail so the surface is
graduation-eligible (M60), and consolidate the four reactive false-positive
fixes into one principled classifier.

## Changes

1. **Codegen-function skip.** A function whose body builds quoted code
   (`quote`/`unquote`/`unquote_splicing`) emits **no** variable candidates.
   Mutating variables in codegen functions breaks the generated code in
   dependents — the M55 gettext (27%) / plug (6%) error tail. Implemented as an
   `:in_codegen` state flag set per-function in `walk_def` (`codegen_body?/1`).

2. **Other-uses gate (VariableReplace).** A swap only fires when the swapped-out
   variable has ≥1 OTHER read in the same function (`candidate.other_uses?`),
   so the swap leaves the name still used — no unused-variable churn /
   warnings-as-errors rollback. Computed as a per-`{module, function, name}`
   read-count post-pass in `collect_variable_candidates`. `VariableToLiteral`
   does NOT require it (a sole-read boundary mutant is still useful).

3. **Single read-side classifier.** `Mut.EnvWalker.variable_read?/2` is now the
   one gate for "is this `{name, meta, atom}` a mutable variable read," with a
   taxonomy comment listing every non-variable shape and where it is handled:
   - name-level (`_`/reserved) — `bindable_var?/1`;
   - env-level (context/scope/trust);
   - bitstring specifier — `:in_bitstring` flag;
   - codegen — `:in_codegen` flag;
   - pipe-rhs / `&`-capture function names — STRUCTURAL in `descend/2` (never
     visited), since they are single non-variable nodes, not regions.
   Binding-side exclusions (pins, bitstring `::`, `\\` defaults) remain in
   `pattern_vars/1`. The four v1.17 reactive fixes (`da89799`, `e3480cd`,
   `06a1280`) all have regression tests; a new shape now has one obvious home.

## Measured impact (gettext, variable-only)

| metric | M55 (v1.17) | M57 |
|---|---:|---:|
| variable_replace candidates | 769 | 298 |
| errors | 211 (27%) | **45 (14.7%)** |
| invalid | nonzero | **0** |

plug (variable-only, capped 1500): errors **202 (6%) → 24 (1.6%)**, invalid 3.

Both targets: error tail cut ~78–88%; residuals are genuine runtime-crash
detections, not codegen/unused-var noise.

## Acceptance

- Variable error rate materially down on gettext (above); plug measured next.
- Regression tests for all four false-positive shapes — green.
- Zero stable-id churn (variable mutators are opt-in; default-plan golden
  unchanged — `bin/verify` green).

*Out of scope:* the default-on flip (M60); broadening the variable surface.
