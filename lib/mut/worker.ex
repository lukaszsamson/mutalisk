defmodule Mut.Worker do
  @moduledoc "Runs mutants in sandboxed Mix test workers."

  alias Mut.Mutant
  alias Mut.Sandbox
  alias Mut.Worker.Formatter

  defmodule Result do
    @moduledoc "Worker execution result."

    @enforce_keys [:status, :duration_ms]
    defstruct [
      :status,
      :duration_ms,
      :killing_test,
      :killing_test_file,
      :raw_output,
      :recompile_category
    ]

    @type status :: :killed | :survived | :timeout | :error | :invalid | :no_coverage
    @type recompile_category ::
            :compile_error | :parse_error | :dep_path_error | :unknown | :timeout | nil
    @type t :: %__MODULE__{
            status: status,
            duration_ms: non_neg_integer,
            killing_test: String.t() | nil,
            killing_test_file: String.t() | nil,
            raw_output: String.t() | nil,
            recompile_category: recompile_category
          }
  end

  @default_timeout_ms 60_000
  @default_test_timeout_ms 10_000
  @max_output_bytes 512_000

  @spec run_schema(Sandbox.t(), non_neg_integer, [String.t()], keyword) :: Result.t()
  def run_schema(%Sandbox{} = sandbox, mutant_id, test_files, opts \\ [])
      when is_integer(mutant_id) and mutant_id >= 0 and is_list(test_files) and is_list(opts) do
    retry? = Keyword.get(opts, :retry_on_error, true)
    result = do_run_schema(sandbox, mutant_id, test_files, opts)

    if retry? and result.status == :error do
      case Sandbox.reset(sandbox) do
        :ok ->
          do_run_schema(sandbox, mutant_id, test_files, Keyword.put(opts, :retry_on_error, false))

        {:error, reason} ->
          %Result{
            status: :error,
            duration_ms: result.duration_ms,
            raw_output:
              "sandbox reset before retry failed: #{inspect(reason)}\n#{result.raw_output}"
          }
      end
    else
      result
    end
  end

  @spec run_fallback(Sandbox.t(), Mutant.t(), [String.t()], keyword) :: Result.t()
  def run_fallback(%Sandbox{} = sandbox, %Mutant{} = mutant, test_files, opts \\ [])
      when is_list(test_files) and is_list(opts) do
    started = System.monotonic_time(:millisecond)

    try do
      with :ok <- validate_sandbox(sandbox),
           {:ok, patch} <- render_patch(sandbox, mutant),
           :ok <- Mut.FallbackPatch.apply(patch, sandbox.path),
           {:ok, manifest} <- read_manifest(sandbox, opts),
           dependents <-
             manifest
             |> Mut.Recompile.dependents(dependent_modules(mutant), dep_kinds(mutant))
             |> Enum.to_list(),
           :ok <- Mut.Recompile.recompile(sandbox, [patch.file], dependents, app: app(opts)) do
        spawn_fallback_mix(sandbox, test_files, opts, started)
      else
        {:error, :missing_source_span} ->
          %Result{
            status: :invalid,
            duration_ms: elapsed(started),
            raw_output: "missing_source_span"
          }

        {:error, {:recompile_failed, category, _code, output} = reason} ->
          %Result{
            status: :invalid,
            duration_ms: elapsed(started),
            raw_output: recompile_output(output, reason),
            recompile_category: category
          }

        {:error, reason} ->
          %Result{status: :error, duration_ms: elapsed(started), raw_output: inspect(reason)}
      end
    rescue
      exception ->
        %Result{
          status: :error,
          duration_ms: elapsed(started),
          raw_output: Exception.message(exception)
        }
    after
      # R6: the fallback path recompiles mutated source INTO the sandbox, so it
      # must be restored before the next mutant reuses it. `reset/1` is
      # self-healing (re-copies any mismatched file from the baseline), so a
      # failure is either a transient FS race — retried once — or a genuinely
      # poisoned sandbox, which we refuse to return silently to the pool: a
      # contaminated sandbox produces FALSE verdicts for every subsequent mutant
      # run on it. Raising here is the safe direction (loud abort over silent
      # wrong answers). Schema runs never dirty the sandbox (the mutant is
      # selected at runtime via MUT_ACTIVE), so only this path resets.
      reset_sandbox!(sandbox)
    end
  end

  defp reset_sandbox!(sandbox) do
    case Sandbox.reset(sandbox) do
      :ok ->
        :ok

      {:error, _reason} ->
        case Sandbox.reset(sandbox) do
          :ok ->
            :ok

          {:error, reason} ->
            raise "sandbox #{sandbox.id} could not be reset after a fallback run " <>
                    "(would contaminate later mutants): #{inspect(reason)}"
        end
    end
  end

  @spec env(non_neg_integer) :: [{String.t(), String.t()}]
  def env(mutant_id) when is_integer(mutant_id) and mutant_id >= 0 do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_schema"},
      {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
      {"MUTALISK_ROLE", "worker"},
      {"MUTALISK_PATH", Path.expand(File.cwd!())},
      {"MUT_ACTIVE", Integer.to_string(mutant_id)}
      | crash_dump_env()
    ]
  end

  # R14: a mutant that crashes the worker BEAM (the common timeout/loop case)
  # otherwise writes a multi-MB `erl_crash.dump` into the child's cwd — which
  # has been observed landing in the host project root. `0` disables the dump
  # entirely; nothing reads it.
  defp crash_dump_env, do: [{"ERL_CRASH_DUMP_SECONDS", "0"}]

  @spec args([String.t()], pos_integer()) :: [String.t()]
  def args(test_files, test_timeout_ms \\ @default_test_timeout_ms)
      when is_list(test_files) and is_integer(test_timeout_ms) and test_timeout_ms > 0 do
    [
      "test",
      "--no-compile",
      "--no-deps-check",
      "--no-archives-check",
      "--max-failures",
      "1",
      # Per-test timeout. Mutation-test workloads need fast detection
      # of infinite loops in mutants; ExUnit's default 60 s was
      # per-target-test, not per-mutant, and dominated wall-clock on
      # Decimal (21 timeouts * 60 s). Tests legitimately needing more
      # can override per-test via @tag timeout:, or raise the global
      # with --test-timeout-ms.
      "--timeout",
      Integer.to_string(test_timeout_ms),
      "--formatter",
      "Mut.Worker.Formatter"
    ] ++ test_files
  end

  defp do_run_schema(sandbox, mutant_id, test_files, opts) do
    started = System.monotonic_time(:millisecond)

    try do
      case validate_sandbox(sandbox) do
        :ok ->
          spawn_mix(sandbox, mutant_id, test_files, opts, started)

        {:error, reason} ->
          %Result{status: :error, duration_ms: elapsed(started), raw_output: inspect(reason)}
      end
    rescue
      exception ->
        %Result{
          status: :error,
          duration_ms: elapsed(started),
          raw_output: Exception.message(exception)
        }
    end
  end

  defp spawn_mix(sandbox, mutant_id, test_files, opts, started) do
    case mix_path(opts) do
      {:ok, mix_path} ->
        port =
          open_mix_port(
            mix_path,
            args(test_files, test_timeout(opts)),
            sandbox.path,
            env(mutant_id)
          )

        port
        |> collect(Keyword.get(opts, :timeout_ms, @default_timeout_ms))
        |> classify(elapsed(started))

      {:error, reason} ->
        %Result{status: :error, duration_ms: elapsed(started), raw_output: inspect(reason)}
    end
  end

  defp spawn_fallback_mix(sandbox, test_files, opts, started) do
    case mix_path(opts) do
      {:ok, mix_path} ->
        port =
          open_mix_port(
            mix_path,
            args(test_files, test_timeout(opts)),
            sandbox.path,
            fallback_env()
          )

        port
        |> collect(Keyword.get(opts, :timeout_ms, @default_timeout_ms))
        |> classify(elapsed(started))

      {:error, reason} ->
        %Result{status: :error, duration_ms: elapsed(started), raw_output: inspect(reason)}
    end
  end

  defp test_timeout(opts), do: Keyword.get(opts, :test_timeout_ms, @default_test_timeout_ms)

  defp render_patch(sandbox, mutant) do
    sandbox.path
    |> Path.join(mutant.file)
    |> File.read!()
    |> then(&Mut.FallbackPatch.render(mutant, &1))
  end

  defp read_manifest(sandbox, opts) do
    if Mut.Umbrella.umbrella?(sandbox.path) do
      # Union every app's manifest so the dependent walk crosses app
      # boundaries (a module mutated in app A yields dependent files in B). M68.
      sandbox.path
      |> Mut.Umbrella.app_names()
      |> Enum.map(&{&1, manifest_path(sandbox, &1)})
      |> Mut.MixManifest.read_combined()
    else
      sandbox
      |> manifest_path(app(opts))
      |> Mut.MixManifest.read()
    end
  end

  defp manifest_path(sandbox, app) do
    Path.join([sandbox.path, "_build/mut_schema/lib", app, ".mix/compile.elixir"])
  end

  # Require an explicit `:app` — the old `"demo_app"` fixture default silently
  # built manifest paths under `_build/mut_schema/lib/demo_app/` for any project,
  # so on a real project every fallback mutant failed to read its manifest and
  # errored. All callers pass `:app`; a missing one is a bug, so fail loudly.
  defp app(opts), do: Keyword.fetch!(opts, :app)

  defp recompile_output("", reason), do: inspect(reason)
  defp recompile_output(output, _reason), do: output

  defp dep_kinds(_mutant), do: [:compile, :struct, :export]

  defp dependent_modules(%Mutant{module: nil}), do: []
  defp dependent_modules(%Mutant{module: module}), do: [module]

  defp validate_sandbox(sandbox) do
    if File.exists?(Path.join(sandbox.path, "mix.exs")) do
      :ok
    else
      {:error, {:sandbox_not_materialized, Path.join(sandbox.path, "mix.exs")}}
    end
  end

  defp mix_path(opts) do
    case Keyword.get(opts, :mix_path) || System.find_executable("mix") do
      nil -> {:error, :mix_not_found}
      path -> {:ok, path}
    end
  end

  defp fallback_env do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_schema"},
      {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
      {"MUTALISK_ROLE", "fallback"},
      {"MUTALISK_PATH", Path.expand(File.cwd!())},
      {"MUT_ACTIVE", "0"}
      | crash_dump_env()
    ]
  end

  defp open_mix_port(mix_path, args, cd, env) do
    Port.open({:spawn_executable, mix_path}, [
      {:args, args},
      {:cd, cd},
      {:env,
       Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)},
      :stderr_to_stdout,
      :exit_status,
      :binary
    ])
  end

  # Absolute monotonic deadline (R2): the host budget is wall-clock from port
  # open, NOT an inactivity timer. The previous `after timeout_ms` reset on
  # every output chunk, so a mutant looping *while printing* (supervisor
  # restart + Logger) never tripped it and wedged the run (Task.async_stream is
  # timeout: :infinity). The deadline is fixed once and the `after` shrinks as
  # time passes, so a chatty hang is killed at the budget like a silent one.
  defp collect(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, "", deadline)
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, bounded_output(output, data), deadline)
      {^port, {:exit_status, code}} -> {:exit, code, output}
    after
      remaining ->
        kill_port(port)
        {:timeout, output}
    end
  end

  defp bounded_output(output, data) do
    combined = output <> data

    if byte_size(combined) <= @max_output_bytes do
      combined
    else
      marker =
        "\n...[mutalisk worker output truncated; retaining last #{@max_output_bytes} bytes]...\n"

      keep_bytes = @max_output_bytes - byte_size(marker)
      marker <> binary_part(combined, byte_size(combined), -keep_bytes)
    end
  end

  defp classify({:timeout, output}, duration_ms) do
    %Result{status: :timeout, duration_ms: duration_ms, raw_output: output}
  end

  defp classify({:exit, code, output}, duration_ms) do
    case Formatter.parse_output(output) do
      # R9: zero tests ran (tag excludes / path filters matched nothing) is NOT
      # a surviving mutant — no test had the chance to detect it. Classifying it
      # `:survived` manufactures false survivors that drag the score down and
      # imply test-suite gaps that don't exist. `:no_coverage` is excluded from
      # the score denominator, like `:skipped`.
      %{summary: %{"total" => 0}} when code == 0 ->
        %Result{status: :no_coverage, duration_ms: duration_ms}

      %{summary: %{"failed" => 0}} when code == 0 ->
        %Result{status: :survived, duration_ms: duration_ms}

      %{summary: %{"failed" => failed}, tests: tests} when code != 0 and failed >= 1 ->
        failing = Enum.find(tests, &(&1["status"] == "failed"))

        %Result{
          status: :killed,
          duration_ms: duration_ms,
          killing_test: killing_test(failing),
          killing_test_file: failing && failing["file"]
        }

      # Nonzero exit with no parsed ExUnit failure (the suite crashed before/at
      # startup, test-helper load, or after the run) is classified :error and
      # excluded from the score denominator. This is DELIBERATELY conservative:
      # some such crashes are mutant-caused (a detection that should count as a
      # kill), but others are genuine infrastructure failures (the SPEC's
      # OOM / sandbox-corruption / port-crash class). Reclassifying the
      # ambiguous bucket as :killed would inflate the headline mutation score
      # with FALSE kills — strictly worse for a mutation-testing tool than the
      # current under-count, since it gives false confidence in test quality.
      # Reliably separating the two needs real-world crash-signature
      # calibration (and the retry-on-error pass already filters transient
      # infra); until then, ambiguous → :error. See review P2.
      _crash ->
        %Result{status: :error, duration_ms: duration_ms, raw_output: output}
    end
  end

  defp killing_test(nil), do: nil
  defp killing_test(test), do: "#{test["module"]} #{test["test"]}"

  # Tree-kill the spawned process (not just the immediate os_pid): under a
  # version manager / wrapper `mix`, the immediate child forks the real BEAM,
  # so `kill -9 <immediate>` orphans the (often infinite-looping) mutant VM on
  # the timeout path. Shared with Mut.ChildProcess via Mut.ProcessTree.
  defp kill_port(port), do: Mut.ProcessTree.kill_port(port)

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
