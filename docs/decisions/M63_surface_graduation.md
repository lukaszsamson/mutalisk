# M63 — graduate what clears: IntegerLiteral-in-pattern → default-on

**Date:** 2026-05-25
**Decision:** Graduate **IntegerLiteral-in-pattern** to the default-on tier.
All other v1.17 surfaces stay opt-in (they do not clear the M62 sharpened
gate). This is the first default-on flip since M46 (AtomLiteral).

## What clears the M62 gate

Per `docs/decisions/M62_equivalent_metric_and_gate.md` (equivalent metric =
covered-survivor upper bound; gate admits a single-target miss ≤ 2pp;
meaningful-sample = n ≥ 10; weak-suite makeup excluded):

| surface | clears? |
|---|---|
| **IntegerLiteral (pattern)** | **YES** — decimal 5.6%, plug 15.6%, ecto 21.1% (single +1.1pp ≤ 2pp miss) |
| AtomLiteral (pattern) | no — ecto 25% (+5pp) AND plug 20.6% (two misses) |
| StringLiteral (pattern) | no — only one meaningful-sample target (plug) |
| Nil/Boolean (pattern) | no — ecto/plug well over |
| VariableReplace | no — 22–39% on jason/ecto/plug |
| VariableToLiteral | no — 37–48% |

Only IntegerLiteral-in-pattern clears → only it graduates.

## Mechanism (per-mutator, per-position graduation)

The literal mutators carry the `:pattern_literal` target and fire in pattern
positions only when that surface is active. Graduating *one* mutator for
pattern positions (not the whole `:pattern_literal` target, which would also
pull in AtomLiteral etc.) is done with a graduated allowlist:

- `Mut.Mutator.Defaults.graduated_pattern_literal_mutators/0 = [IntegerLiteral]`.
- `IntegerLiteral` added to `default_on/0`. Its **body** firing still needs the
  opt-in `:body_literal` target (unchanged), so this only enables
  IntegerLiteral-**in-pattern** by default.
- `Orchestrator.pattern_literal_results/4`: with `--enable pattern_literal`, the
  FULL pattern surface fires (unchanged opt-in behaviour); by default, only the
  graduated allowlist (∩ active mutators) fires. Pattern candidates are already
  discovered by default (`:env_walker`), plus a discovery-gate relaxation so
  they are found whenever a graduated pattern mutator is active.

`--enable pattern_literal` still runs Atom/Nil/Boolean/String-in-pattern
(opt-in), so no surface lost reachability.

## Additive-only (verified)

- **demo_app:** default plan byte-identical (no integer pattern literals;
  golden + integration tests green).
- **Decimal:** default plan gains **18 IntegerLiteral (pattern) mutants**; all
  existing mutators unchanged (Arithmetic 202, AtomLiteral 75, … as before).
  Existing stable IDs untouched — additive only.

`CLI @default_on_mutators` mirrors `Defaults.default_on/0` (parity test green).
`bin/verify` green.

*Out of scope:* the other surfaces (stay opt-in; revisit with more volume /
sharper equivalent detection).
