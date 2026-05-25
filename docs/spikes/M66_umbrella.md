# M66 — umbrella support design spike

**Date:** 2026-05-25
**Verdict: GO.** Umbrella support is feasible with the existing per-target
overlay/build-path machinery extended per-app. A throwaway proof on `~/unilink`
(5 apps, 490 lib files) compiled cleanly under a shared mut build path. No
production code in this milestone beyond the throwaway proof.

## Proof (unilink, throwaway)

Copied unilink source (no `_build`/`deps`), injected
`{:mutalisk, path: …, only: [:test], runtime: true}` into **each app's** deps,
then `deps.get` + `compile` under `MIX_BUILD_PATH=_build/mut_oracle`,
`MIX_DEPS_PATH=_build/mut_oracle/deps`, `MIX_ENV=test`:

- `deps.get`: ok (27 s).
- `compile`: ok (73 s wall, first full compile of 5 apps + deps + mutalisk).
- Layout produced: `_build/mut_oracle/lib/{backoffice,unilink,unilink_backend,
  unilink_background,unilink_tracking}/ebin` **+** `…/lib/mutalisk/ebin` — all
  apps and mutalisk share one build root, mutalisk visible to every app.

So the single-app overlay model (wrap project, inject `:mutalisk` + the
`:mut_oracle` compiler) generalizes to umbrellas by applying it **per child
app**, leaving the umbrella root's `apps_path` project intact.

## Cross-app dependency graph (the crux)

unilink's inter-app deps (`in_umbrella: true`):

```
unilink            (hub; no in_umbrella deps)
backoffice         -> unilink
unilink_backend    -> unilink
unilink_background -> unilink
unilink_tracking   -> unilink
```

A mutant in **unilink** (the hub) changes a module that 4 other apps depend on
at compile time — its fallback recompile must rebuild those 4 dependent apps,
and its test selection must include their tests. This is the M68 correctness
crux.

## Design

### Work copy + overlay (M67)

- The umbrella work copy materializes the root + `apps/` (root `mix.exs`,
  `apps/<app>/mix.exs`, `apps/<app>/lib`, `config/`).
- `Mut.Bootstrap.Overlay`: replace `assert_not_umbrella!` (the v1 raise) with an
  **umbrella branch**. Detect `apps_path`; for each `apps/<app>/mix.exs`, apply
  the existing wrap (inject `:mutalisk` dep + role compiler).

> **M67 correction.** The spike assumed the root could stay untouched ("per-app
> injection suffices"). The proof only exercised a plain `mix compile`, not the
> `:mut_oracle` compiler. In practice Mix runs `deps.loadpaths` **once at the
> umbrella root** and then `compile.all` **per child** (no per-child
> loadpaths). So if `:mutalisk` is not on the *root's* deps, its ebin never
> joins the code path and `compile.mut_oracle` is undiscoverable in every
> child. M67 therefore wraps the **root too** (injecting the `:mutalisk` dep;
> the root never runs the prepended compiler since umbrella roots delegate
> compilation). Two further umbrella-only hazards the spike missed, both fixed
> in M67: the per-app wrappers must use **distinct module names** (else they
> redefine `Mutalisk.WrappedMixProject` in one BEAM, corrupting
> `Mix.Project.get!()`), and the `:mut_oracle` compiler must be **idempotent**
> (it runs once per child app in the same BEAM — the tracer must be registered
> once and the JSONL Writer started once, not truncated per app).

### Build-Path Contract extension (M67)

- Per-app ebins under the shared `_build/mut_<role>/lib/<app>/ebin`; mutalisk +
  deps siblings under the same root; `MIX_DEPS_PATH=_build/mut_<role>/deps`
  (proven). No per-app build roots — one shared root, as Mix does natively for
  umbrellas.

### Oracle / schema / fallback / sandbox (M67/M68)

- **Oracle:** the `:mut_oracle` compiler runs per app (each app's compile is
  traced); dispatch sites are collected per app. Produce **per-app plans**
  keyed by app + file.
- **Schema:** `SchemaPlacer` works per file regardless of app; the instrumented
  umbrella is built once under the shared schema build root. Mutant selection
  (persistent_term) is global.
- **Fallback (M68):** per-app Mix manifest reading
  (`_build/mut_schema/lib/<app>/.mix/compile.elixir`); the dependency walk
  **unions across apps** — `Mut.MixManifest.dependents` extended so a module in
  app A yields dependent files in app B. The recompile rebuilds the mutated
  app **and** its cross-app dependents before the targeted test run.
- **Sandbox:** reset restores every affected app's `lib/<app>/ebin` +
  `.mix/compile.elixir` (today it sweeps one user app; M68 generalizes to all
  umbrella apps).

### Cross-app dependency walk algorithm (M68)

1. Read every app's Mix manifest (modules → source file, compile/export/struct
   deps) into a unified `{app, module} → file` map and a global dep graph.
2. For a mutant in module M (app A): `dependents(M)` = transitive compile-dep
   closure + direct export/struct deps, **spanning apps** (M's dependents may
   live in app B). Recompile = mutated file + all dependent files, across apps.
3. Test selection: union the tests of all apps whose recompiled files changed.

## v1.20 implementation scope

- **M67:** umbrella work copy + overlay (per-app), build-path extension, oracle
  per-app, schema across apps, sandbox umbrella-aware. Single-app path stays
  byte-identical (the umbrella branch is gated on `apps_path` detection).
- **M68:** per-app manifest reading + cross-app dependency walk + cross-app
  fallback recompile + multi-app sandbox reset.

## Go/no-go

**GO.** Feasibility proven (compiles under the mut build path; per-app overlay +
shared build root work). The one hard piece (cross-app dependents) has a
concrete algorithm above. Risk is contained to a new umbrella branch gated on
`apps_path`; the single-app path is untouched. Cost (~73 s full compile on a
5-app umbrella) is acceptable for the oracle/schema one-time builds.
