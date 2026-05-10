defmodule Mut.Drift.Bucketer do
  @moduledoc """
  Auto-classify mix-vs-persistent stable-id status drift by heuristic.

  Consumes pairs of Stryker-format reports — one produced under
  `--worker-type mix`, one under `--worker-type persistent` — and
  partitions the union of mutant ids into four primary sets:

    * `:agree_killed`
    * `:agree_survived`
    * `:mix_killed_persistent_survived`  (false negatives — persistent misses)
    * `:mix_survived_persistent_killed`  (false positives — persistent over-kills)

  Mutants whose statuses differ in any other way (e.g.
  `Killed`/`CompileError`, `Survived`/`Timeout`) are treated as drift
  and bucketed by heuristic alongside the two clean false-flip
  classes. Mutants present in only one report land in `:mix_only` /
  `:persistent_only` (should be empty for matched runs).

  ## Heuristic buckets

  Each drifting mutant is assigned exactly one bucket. Heuristics
  fire in priority order; the first match wins.

    * `:timeout_flap`    — either side's status is `Timeout`
                           (V17 acceptance class).
    * `:gettext_class`   — target/file path matches gettext, the
                           drift involves a persistent crash or
                           runtime error (boot-time/recompile
                           macro failure).
    * `:mox_class`       — target/file path matches mox, OR the
                           target name is `mox`. Module-replacement
                           state leaks across mutants.
    * `:ecto_warm_state` — target/file path matches ecto/ecto_sql
                           AND mix=Killed while persistent
                           survived/crashed/errored. The warm BEAM
                           is masking errors mix-spawn surfaces.
    * `:ecto_false_kill` — target/file path matches ecto/ecto_sql
                           AND mix=Survived while persistent=Killed.
                           Leaked compile-cache produces false
                           positives.
    * `:parse_class`     — persistent statusReason carries
                           SyntaxError / MismatchedDelimiter /
                           parse_error markers, OR the mutant is a
                           CompileError on persistent that mix did
                           not compile-error.
    * `:pool_warm_state` — target/file matches HTTP-client or
                           process-pool shapes (mint, finch,
                           nimble_pool, plug, hackney, …) AND the
                           drift is mix=Survived → persistent=Killed
                           (warm BEAM holds connection/pool state
                           that propagates across mutants). M27
                           surfaced this on mint v1.8.0 and
                           nimble_pool v1.1.0.
    * `:supervisor_init` — `mix=RuntimeError → persistent={Killed,
                           Survived}`. Mix-spawn re-runs
                           `Application.start/2` per fallback
                           mutant, so mutations that break
                           supervised initialization surface as
                           test-framework RuntimeError under mix.
                           Persistent worker doesn't re-run init,
                           so the same mutation reaches tests
                           against an already-initialized
                           supervisor tree. M30 documented this on
                           ecto (caught by `:ecto_warm_state`);
                           M35 promoted the generic case to its
                           own bucket after plug v1.19.1 surfaced
                           the same pattern outside ecto.
    * `:unclassified`    — anything else.

  Heuristics are best-effort. They consume only data observable in
  the Stryker report — file path, statusReason text, and the target
  name passed in. They don't read the target's `mix.exs` or its
  loaded applications. v1.12+ may refine by reading `mutalisk.engine`
  routing or surfacing dep info via the bench harness.
  """

  alias Mut.Drift.Bucketer.Result

  @type stryker :: map()
  @type bucket ::
          :timeout_flap
          | :gettext_class
          | :mox_class
          | :ecto_warm_state
          | :ecto_false_kill
          | :parse_class
          | :pool_warm_state
          | :supervisor_init
          | :unclassified

  @drift_buckets [
    :mox_class,
    :ecto_warm_state,
    :ecto_false_kill,
    :gettext_class,
    :parse_class,
    :pool_warm_state,
    :supervisor_init,
    :timeout_flap,
    :unclassified
  ]

  @spec drift_buckets() :: [bucket()]
  def drift_buckets, do: @drift_buckets

  @doc """
  Compare a mix-mode and persistent-mode Stryker report for one
  target. Returns a `Result` struct summarising agreement, drift,
  and per-bucket counts.

  `target` is a string label used by heuristics that key on target
  name (e.g. `"mox"`, `"ecto"`, `"gettext"`). It can be `nil` —
  heuristics then fall back to file-path matching alone.
  """
  @spec analyze(stryker(), stryker(), String.t() | nil) :: Result.t()
  def analyze(mix_report, persistent_report, target \\ nil)
      when is_map(mix_report) and is_map(persistent_report) do
    mix_mutants = index_mutants(mix_report)
    persistent_mutants = index_mutants(persistent_report)

    all_ids =
      MapSet.union(MapSet.new(Map.keys(mix_mutants)), MapSet.new(Map.keys(persistent_mutants)))

    Enum.reduce(all_ids, Result.new(target), fn id, acc ->
      mix = Map.get(mix_mutants, id)
      persistent = Map.get(persistent_mutants, id)
      classify_pair(acc, id, mix, persistent, target)
    end)
  end

  defp classify_pair(acc, id, nil, persistent, _target) when is_map(persistent) do
    Result.add_persistent_only(acc, id)
  end

  defp classify_pair(acc, id, mix, nil, _target) when is_map(mix) do
    Result.add_mix_only(acc, id)
  end

  defp classify_pair(acc, id, mix, persistent, target) do
    mix_status = mix["status"]
    persistent_status = persistent["status"]

    cond do
      mix_status == "Killed" and persistent_status == "Killed" ->
        Result.add_agree_killed(acc, id)

      mix_status == "Survived" and persistent_status == "Survived" ->
        Result.add_agree_survived(acc, id)

      mix_status == persistent_status ->
        # Both sides agree on a non-Killed/Survived status (e.g. both
        # CompileError, both Timeout). Not drift. Count as agreement
        # under whichever status; here we track as `agree_other` so
        # the report distinguishes "real agreement" from drift.
        Result.add_agree_other(acc, id, mix_status)

      true ->
        bucket = bucket_for(mix, persistent, target)
        Result.add_drift(acc, id, mix_status, persistent_status, bucket)
    end
  end

  @doc """
  Classify a single drifting mutant pair. Exposed for unit tests
  and for use from external callers (e.g. an interactive REPL).
  """
  @spec bucket_for(map(), map(), String.t() | nil) :: bucket()
  def bucket_for(mix, persistent, target) do
    # Heuristics ranked from most-specific to least-specific.
    # Adding a heuristic = append `{name, predicate}` to the list.
    heuristics = [
      {:timeout_flap, fn -> timeout_flap?(mix, persistent) end},
      {:gettext_class, fn -> gettext_class?(mix, persistent, target) end},
      {:mox_class, fn -> mox_class?(mix, persistent, target) end},
      {:ecto_warm_state, fn -> ecto_warm_state?(mix, persistent, target) end},
      {:ecto_false_kill, fn -> ecto_false_kill?(mix, persistent, target) end},
      {:parse_class, fn -> parse_class?(mix, persistent) end},
      {:pool_warm_state, fn -> pool_warm_state?(mix, persistent, target) end},
      {:supervisor_init, fn -> supervisor_init?(mix, persistent) end}
    ]

    case Enum.find(heuristics, fn {_name, pred} -> pred.() end) do
      {bucket, _} -> bucket
      nil -> :unclassified
    end
  end

  ## ---- predicates ---------------------------------------------------------

  defp timeout_flap?(mix, persistent) do
    mix["status"] == "Timeout" or persistent["status"] == "Timeout"
  end

  defp gettext_class?(mix, persistent, target) do
    target_match?(target, mix, persistent, ["gettext"]) and
      (persistent["status"] in ["RuntimeError", "CompileError"] or
         mix["status"] == "Killed")
  end

  defp mox_class?(mix, persistent, target) do
    target_match?(target, mix, persistent, ["mox"]) and
      mix["status"] in ["Killed", "Survived"] and
      persistent["status"] in ["Killed", "Survived"]
  end

  defp ecto_warm_state?(mix, persistent, target) do
    target_match?(target, mix, persistent, ["ecto", "ecto_sql"]) and
      ((mix["status"] == "Killed" and
          persistent["status"] in ["Survived", "RuntimeError", "CompileError"]) or
         (mix["status"] in ["RuntimeError", "CompileError", "Timeout"] and
            persistent["status"] in ["Killed", "Survived", "CompileError"]))
  end

  defp ecto_false_kill?(mix, persistent, target) do
    target_match?(target, mix, persistent, ["ecto", "ecto_sql"]) and
      mix["status"] == "Survived" and
      persistent["status"] == "Killed"
  end

  defp parse_class?(mix, persistent) do
    parse_signal?(persistent["statusReason"]) or
      (persistent["status"] == "CompileError" and mix["status"] != "CompileError")
  end

  defp parse_signal?(nil), do: false
  defp parse_signal?(""), do: false

  defp parse_signal?(reason) when is_binary(reason) do
    String.contains?(reason, [
      "SyntaxError",
      "MismatchedDelimiter",
      "TokenMissingError",
      "parse_error"
    ])
  end

  defp parse_signal?(_), do: false

  # M27 surfaced this on mint v1.8.0 and nimble_pool v1.1.0: the
  # warm persistent BEAM accumulates HTTP-client / process-pool
  # state (sockets, pool workers, registry entries) that mix-spawn
  # would re-create per run, producing false-positive `Killed`s on
  # mutants mix marks `Survived`. Different root cause from Ecto's
  # planner-cache leak but same drift direction. Apps in this
  # bucket: HTTP clients (mint, finch, hackney, gun) and process
  # pools (nimble_pool, plug — Plug.Conn pool, poolboy).
  @pool_app_names ~w(mint finch hackney gun nimble_pool plug poolboy connection)

  defp pool_warm_state?(mix, persistent, target) do
    target_match?(target, mix, persistent, @pool_app_names) and
      mix["status"] == "Survived" and
      persistent["status"] == "Killed"
  end

  # M35: generic supervisor-init drift class. Mix-spawn re-runs
  # `Application.start/2` per fallback mutant, so mutations that
  # break supervised initialization surface as a test-framework
  # `RuntimeError` under mix. Persistent worker loads apps once at
  # boot — the mutation reaches tests against an already-
  # initialized supervisor tree, which often kills cleanly. M30
  # documented this on ecto (caught earlier by `:ecto_warm_state`);
  # M35 promoted the generic case after plug v1.19.1 surfaced the
  # same pattern outside ecto. Ranked AFTER target-specific buckets
  # so ecto / mox / pool-class flips still attribute to their named
  # buckets first.
  defp supervisor_init?(mix, persistent) do
    mix["status"] == "RuntimeError" and persistent["status"] in ["Killed", "Survived"]
  end

  ## ---- target / file-path matching ---------------------------------------

  defp target_match?(target, mix, persistent, app_names) do
    target_name_match?(target, app_names) or
      file_path_match?(mix, app_names) or
      file_path_match?(persistent, app_names)
  end

  defp target_name_match?(nil, _), do: false

  defp target_name_match?(target, app_names) when is_binary(target) do
    Enum.member?(app_names, String.downcase(target))
  end

  defp file_path_match?(nil, _), do: false

  defp file_path_match?(mutant, app_names) do
    case mutant["__file__"] do
      path when is_binary(path) ->
        lower = String.downcase(path)
        Enum.any?(app_names, fn name -> String.contains?(lower, name) end)

      _ ->
        false
    end
  end

  ## ---- indexing ----------------------------------------------------------

  defp index_mutants(report) do
    files = Map.get(report, "files", %{})

    files
    |> Enum.flat_map(fn {path, %{"mutants" => mutants}} when is_list(mutants) ->
      Enum.map(mutants, &Map.put(&1, "__file__", path))
    end)
    |> Map.new(&{&1["id"], &1})
  end
end
