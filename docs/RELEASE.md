# Releasing Mutalisk

v1.30 made the repository **release-ready**: license, Hex metadata, HexDocs
config, and a user-facing CHANGELOG are all in place, and every gate is green.
Publishing itself is a deliberate **manual** step — this document is the
checklist and the exact commands.

The published package version is **`0.1.0`** (pre-1.0: the public surface — CLI
flags, config keys, report shape — is stable in practice but may still change
before `1.0.0`).

## Release-readiness checklist

All of these are green as of v1.30 / M112 (re-run before publishing):

- [ ] `bin/verify` green (lint, unit, dialyzer, golden, integration, e2e).
- [ ] `mix format --check-formatted` clean.
- [ ] `mix compile --warnings-as-errors` clean.
- [ ] `mix credo --strict` clean.
- [ ] `mix dialyzer` clean.
- [ ] `mix docs` builds with **no warnings** (no broken refs).
- [ ] `mix hex.build` packages successfully (valid metadata, Apache-2.0, no
      license-mismatch warnings). Inspect the file list — `lib` (excluding the
      internal-only `lib/mix/tasks/mut/` dev/CI tasks), `mix.exs`, `README.md`,
      `LICENSE`, `CHANGELOG.md`, `docs/MUTATORS.md` ship.
- [ ] `LICENSE` is verbatim Apache License 2.0.
- [ ] `CHANGELOG.md` has the `0.1.0` entry.
- [ ] No stray/cruft files at the repo root.

## One-time setup (before the first publish)

1. **Confirm the public git remote.** The remote already exists, `main` is
   pushed, and CI is green; this is a verification step, not setup. The
   `@source_url` in `mix.exs` and the absolute repo links in `README.md` assume
   `https://github.com/lukaszsamson/mutalisk` — confirm `git remote -v` matches,
   and if a different owner/URL is used, update `@source_url` in `mix.exs` and
   the `Project documents` links in `README.md` to match.

2. **Hex account** — authenticate once: `mix hex.user auth` (or `register`).

## Publish steps (each release)

> These steps push and publish — run them only when intentionally cutting a
> public release.

1. Re-run the readiness checklist above (especially `bin/verify`).
2. Confirm the version in `mix.exs` (`@version`) and the matching
   `CHANGELOG.md` entry.
3. Push the branch and tag the release:

   ```sh
   git push -u origin main
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. Publish the package to Hex:

   ```sh
   mix hex.publish
   ```

   Review the file list and metadata at the prompt before confirming.

5. Publish the docs to HexDocs (usually done by `mix hex.publish`; run
   explicitly if needed):

   ```sh
   mix hex.publish docs
   ```

## Notes

- **`--incremental`** ships opt-in. Making it the default is a future decision,
  gated on real CI adoption (see `PLAN.md` v1.30 horizon).
- The `priv/plts/` Dialyzer PLT and the unused `priv/stryker_schema_v2.json`
  are **excluded** from the package (`files` in `mix.exs`) — Mutalisk reads no
  `priv/` at runtime.
- `source_ref` in the docs config is `"main"`; the remote exists and `main` is
  pushed, so source links resolve correctly. Bump to `"v<version>"` if you
  prefer tag-pinned source links.
