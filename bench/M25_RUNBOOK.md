# M25 Phase B Runbook

This runbook covers the remaining 5 targets of the M25 v1.10 validation
matrix. `nimble_options` was run as a pilot in commit `914b69f`.
Targets remaining: `gettext`, `ecto`, `mox`, `jason`, optionally `plug`.

SHAs are pinned in `bench/run.sh` (commit `feff0f9`). All commands below
assume `pwd` is the repo root and `bin/verify` is green at HEAD.

## Per-target commands

Each target runs in 4 modes. Run sequentially (not in parallel) on a
single host — `--concurrency 4` already saturates CPU per run.

```bash
# Pattern (substitute <T> with target name):
bench/run.sh --target <T> --concurrency 4 --worker-type mix
bench/run.sh --target <T> --concurrency 4 --worker-type persistent
bench/run.sh --target <T> --concurrency 4 --worker-type mix --enable-body-literal
bench/run.sh --target <T> --concurrency 4 --worker-type persistent --enable-body-literal
```

Each invocation produces two files in `bench/results/`:
- `<target>.static.c4[.persistent][.body_literal].stryker.json`
- `<target>.static.c4[.persistent][.body_literal].terminal.txt`

## Per-target gotchas

### gettext (v1.0.2)
Heavy compile-time macros. The harness's `mix deps.get` + `mix mut`
chain handles compilation, but if you see compile errors before any
mutants run, the upstream macro expansion changed; re-pin to a known
clean tag.

### ecto (v3.13.6)
Ecto core (not `ecto_sql`). Many tests require a live DB. The harness
runs `mix mut` which calls `mix test` internally; tests requiring
PostgreSQL/MySQL will fail with a connection error and inflate the
RuntimeError count. To exclude, edit the cloned tree's
`tmp/bench/ecto/test/test_helper.exs` after the harness checks out
the SHA but before `mix mut` runs. Easiest: stop the harness after
clone, edit, restart with `--no-clone`-style flag (not currently
supported — extend `bench/run.sh` if needed) OR pre-stage the
worktree manually:

```bash
WORK=tmp/bench/ecto
git clone https://github.com/elixir-ecto/ecto.git "$WORK"
git -C "$WORK" checkout 285329f63d34b610d754fd16d07f6c95ae52bfc7
# Inject ExUnit exclude:
cat > "$WORK/test/test_helper.exs" <<'EOF'
ExUnit.start(exclude: [:integration, :postgres, :mysql], seed: 42)
EOF
# Then run the matrix; harness will re-clone unless you also patch run.sh
# to skip clone when WORK_DIR is populated. Document the run as
# "ecto, no-DB subset" in BENCHMARKS.
```

ecto is the longest run (~25-60 min per mode). Budget ~2-4h for all 4 modes.

### mox (v1.2.0)
**Highest-risk target for persistent worker.** Mox uses module-replacement
at runtime via `:meck`-style state in `Mox.Server`. Persistent worker's
reset hooks (application_env + ets) do NOT clear Mox.Server state. Expect
some persistent runs to fail or drift. That failure IS the data point.

If `--worker-type persistent` mode hangs or produces 100% RuntimeError,
document and proceed — this is exactly the unsupported-pattern signal
M25 is designed to surface.

### jason (v1.4.5)
Uses StreamData. Pin a fixed seed by patching test_helper.exs in the
cloned tree:

```bash
WORK=tmp/bench/jason
git clone https://github.com/michalmuskala/jason.git "$WORK"
git -C "$WORK" checkout 4ede42858eb19f80ec9e863aab52df466eab8608
# Replace ExUnit.start() line:
perl -pi -e 's/ExUnit\.start\(\)/ExUnit.start(seed: 42)/' "$WORK/test/test_helper.exs"
```

Without a pinned seed, kill rates drift between runs and byte-identity
fails for non-bug reasons. **Document seed=42 in BENCHMARKS.md** when
recording jason results.

### plug (v1.19.1, optional)
Largest target, ~30-90 min per mode. Skip unless ecto data is
inconclusive and a 6th data point is needed for the default-flip
gate (≥4 of 5 OSS targets clean).

## Commit pacing

After each target's 4 runs complete:

```bash
git add bench/results/<target>.*
git commit -m "M25 Phase B: <target> bench results (mix + persistent x baseline + body_literal)"
```

Include in the commit message: total mutant counts (baseline & body-literal),
any drift count (use the analysis snippet below), and any failure modes.

## Per-target byte-identity check (Phase C C.1)

After each target, run this snippet to quantify drift between mix and
persistent at the same body_literal mode. Replace `<T>` and `<MODE>`
where `<MODE>` is empty string for baseline or `.body_literal`:

```bash
ROOT="$(pwd)" T=<target> MODE='' elixir --eval '
Mix.install([{:jason, "~> 1.4"}])
mode = System.get_env("MODE", "")
t = System.fetch_env!("T")
mix_path = "bench/results/#{t}.static.c4#{mode}.stryker.json"
per_path = "bench/results/#{t}.static.c4.persistent#{mode}.stryker.json"
extract = fn p ->
  p |> File.read!() |> Jason.decode!()
    |> get_in(["files"]) |> Map.values()
    |> Enum.flat_map(& &1["mutants"])
    |> Map.new(fn m -> {m["id"], {m["status"], m["mutatorName"]}} end)
end
mix_m = extract.(mix_path)
per_m = extract.(per_path)
common = MapSet.intersection(MapSet.new(Map.keys(mix_m)), MapSet.new(Map.keys(per_m)))
diffs = Enum.filter(common, fn id -> elem(mix_m[id], 0) != elem(per_m[id], 0) end)
IO.puts("target=#{t} mode=#{if mode == "", do: "baseline", else: "body_literal"} total=#{MapSet.size(common)} drift=#{length(diffs)}")
by_pair = Enum.reduce(diffs, %{}, fn id, acc ->
  {ms, mn} = mix_m[id]
  {ps, _} = per_m[id]
  Map.update(acc, {ms, ps, mn}, 1, &(&1 + 1))
end)
Enum.each(by_pair, fn {{ms, ps, mn}, n} -> IO.puts("  mix=#{ms} persistent=#{ps} mutator=#{mn} count=#{n}") end)
'
```

V17 acceptance: drift is acceptable only if all drift cases are
`Killed <-> Survived` boundary flips on mutants with wall-clock near
10s timeout. Any `CompileError` or `RuntimeError` flip is unsupported-
pattern signal — document in PERSISTENT_WORKER_GUIDE.md.

## Per-target body-literal impact (Phase C C.2)

```bash
ROOT="$(pwd)" T=<target> WT=mix elixir --eval '
Mix.install([{:jason, "~> 1.4"}])
t = System.fetch_env!("T")
wt = System.fetch_env!("WT")
suffix = if wt == "mix", do: "", else: ".persistent"
base_path = "bench/results/#{t}.static.c4#{suffix}.stryker.json"
bl_path   = "bench/results/#{t}.static.c4#{suffix}.body_literal.stryker.json"
extract = fn p ->
  p |> File.read!() |> Jason.decode!()
    |> get_in(["files"]) |> Map.values()
    |> Enum.flat_map(& &1["mutants"])
    |> Map.new(fn m -> {m["id"], {m["status"], m["mutatorName"]}} end)
end
base = extract.(base_path)
bl = extract.(bl_path)
new_ids = MapSet.difference(MapSet.new(Map.keys(bl)), MapSet.new(Map.keys(base)))
new_mutants = Enum.map(new_ids, &bl[&1])
counts = Enum.reduce(new_mutants, %{}, fn {st, mn}, acc ->
  Map.update(acc, {mn, st}, 1, &(&1 + 1))
end)
killed = new_mutants |> Enum.count(fn {st, _} -> st == "Killed" end)
total = MapSet.size(new_ids)
kill_rate = if total > 0, do: Float.round(killed / total * 100, 1), else: 0.0
IO.puts("target=#{t} worker=#{wt} new_mutants=#{total} killed=#{killed} kill_rate=#{kill_rate}%")
Enum.each(counts, fn {{mn, st}, n} -> IO.puts("  #{mn}/#{st}: #{n}") end)
'
```

For each target × worker combo, record `new_mutants`, `killed`,
`kill_rate` in the BENCHMARKS.md "v1.10 validation matrix" section.

## Decision criteria reminders

After all targets land, apply criteria from PLAN.md M25 Phase D:

**Decision 1 (body-literal default):**
- Default-on iff (avg kill rate ≥60% across non-jason targets) AND
  (equivalent-mutant rate <20%) AND (zero invalid body-literal mutants).
- Trim table iff `n → n+1` survivor rate >50% across multiple targets.
- Else keep opt-in.

**Decision 2 (body-literal routing):**
- Stay fallback iff body-literal contribution to wall-clock <15% on
  largest target.
- Else: scope schema migration into v1.11 (no v1.10 code change).

## Failure handling

- If a single run fails: write `bench/results/<target>.<mode>.failure.txt`
  capturing stderr + last 50 lines of stdout, then continue.
- If `mix mut` itself crashes the host BEAM: STOP. Document in
  CONCERNS.txt or new file. Roll back recent commits if needed.
- If a target's whole 4-mode set fails: continue with other targets;
  the failure is data, not a blocker.

## Pilot finding (nimble_options)

Recorded in commit `914b69f`. Headline: 35/72 mutants drift mix vs
persistent on baseline (29 GuardTypeTest, 4 GuardComparison, 2 misc),
all flipping to CompileError under persistent. Body-literal-enabled
persistent run drifts 13/86 — non-deterministic. Phase C will
aggregate this with the other targets to decide on
PERSISTENT_WORKER_GUIDE.md unsupported-pattern entries.
