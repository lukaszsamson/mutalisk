defmodule Mut.Worker do
  @moduledoc "Runs mutants in sandboxed Mix test workers."

  alias Mut.Mutant
  alias Mut.Sandbox
  alias Mut.Worker.Formatter
  alias Mut.Worker.Persistent

  defmodule Result do
    @moduledoc "Worker execution result."

    @enforce_keys [:status, :duration_ms]
    defstruct [:status, :duration_ms, :killing_test, :raw_output, :recompile_category]

    @type status :: :killed | :survived | :timeout | :error | :invalid
    @type recompile_category :: :compile_error | :parse_error | :dep_path_error | :unknown | nil
    @type t :: %__MODULE__{
            status: status,
            duration_ms: non_neg_integer,
            killing_test: String.t() | nil,
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
      Sandbox.reset(sandbox)
    end
  end

  @doc """
  M21 in-process fallback recompile path.

  Same prepare-patch flow as `run_fallback/4` (validate sandbox,
  render + apply patch, read manifest, compute dependents) but
  delegates the recompile + test execution to the persistent BEAM
  via `Mut.Worker.Persistent.run_fallback/5` instead of spawning
  a fresh `mix test`. The persistent BEAM compiles the patched
  files in-process, runs ExUnit, and restores originals from the
  schema-build ebins.

  On `:filter_miss` / `:timeout` / `:crashed`, falls back to the
  mix-spawn path (`run_fallback/4`) for the same sandbox + mutant.
  On `:compile_error`, materialises a Result with status: :invalid
  and the appropriate `recompile_category` — mix-retry would just
  fail with the same compile error.

  Always calls `Sandbox.reset/1` in the `after` clause to revert
  the source patch, matching `run_fallback/4`'s semantics.
  """
  @spec run_fallback_in_process(
          GenServer.server(),
          Sandbox.t(),
          Mutant.t(),
          [String.t()],
          keyword
        ) ::
          Result.t()
  def run_fallback_in_process(
        server,
        %Sandbox{} = sandbox,
        %Mutant{} = mutant,
        test_files,
        opts \\ []
      )
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
             |> Enum.to_list() do
        compile_files = [patch.file | dependents]

        case Persistent.run_fallback(
               server,
               mutant.id,
               compile_files,
               test_files,
               timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
             ) do
          %Result{} = result ->
            %{result | duration_ms: elapsed(started)}

          {:compile_error, category, message} when category in [:unknown, :parse_error] ->
            # M25 diagnosis (nimble_options): in-process recompile
            # failures in two categories disagree systematically with
            # mix-spawn:
            #
            #   `:unknown` — patched file's compile-time code raised a
            #     non-CompileError exception (e.g., FunctionClauseError)
            #     inside `Code.compile_file/1`. Persistent BEAM state is
            #     the cause; a fresh `Kernel.ParallelCompiler` subprocess
            #     accepts the same patch.
            #
            #   `:parse_error` — `MismatchedDelimiterError` / `SyntaxError`
            #     / `TokenMissingError` on patched bytes that mix-spawn
            #     parses cleanly. Same source bytes, different parser
            #     verdict; observed on nimble_options' guard mutants.
            #
            # Both route to mix-spawn for an authoritative verdict (same
            # recovery contract as `:filter_miss | :timeout | :crashed`).
            # The patch is still applied to the sandbox. If mix-spawn
            # ALSO fails, the resulting `%Result{status: :invalid,
            # recompile_category: ...}` is the truthful verdict and
            # matches the mix-only baseline.
            #
            # We DO NOT fall back for `:compile_error` and
            # `:dep_path_error` — those are taxonomies the in-process
            # path agrees with mix-spawn on, and falling back would
            # double-cost every truly broken patch.
            _persistent_message = message
            _persistent_category = category
            run_fallback(sandbox, mutant, test_files, opts)

          {:compile_error, category, message} ->
            %Result{
              status: :invalid,
              duration_ms: elapsed(started),
              raw_output: message,
              recompile_category: category
            }

          reply when reply in [:filter_miss, :timeout, :crashed] ->
            # Persistent path couldn't deliver a verdict. Fall back to
            # the mix-spawn fallback for this single mutant; the
            # source patch is still applied and Sandbox.reset in the
            # `after` clause will revert. We re-run the FULL prepare
            # flow inside run_fallback/4 because Sandbox.reset has
            # not yet fired — but that double-render is cheap, and
            # this branch is rare on real targets.
            run_fallback(sandbox, mutant, test_files, opts)
        end
      else
        {:error, :missing_source_span} ->
          %Result{
            status: :invalid,
            duration_ms: elapsed(started),
            raw_output: "missing_source_span"
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
      Sandbox.reset(sandbox)
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
    ]
  end

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
      # Match the persistent runner's per-test timeout so mix and
      # persistent are comparable apples-to-apples. Mutation-test
      # workloads need fast detection of infinite loops in mutants;
      # ExUnit's default 60 s was per-target-test, not per-mutant,
      # and dominated wall-clock on Decimal (21 timeouts * 60 s).
      # Tests legitimately needing more can override per-test via
      # @tag timeout:, or raise the global with --test-timeout-ms.
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
        |> collect("", Keyword.get(opts, :timeout_ms, @default_timeout_ms))
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
        |> collect("", Keyword.get(opts, :timeout_ms, @default_timeout_ms))
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
    [sandbox.path, "_build/mut_schema/lib", app(opts), ".mix/compile.elixir"]
    |> Path.join()
    |> Mut.MixManifest.read()
  end

  defp app(opts), do: Keyword.get(opts, :app, "demo_app")

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

  defp collect(port, output, timeout_ms) do
    receive do
      {^port, {:data, data}} -> collect(port, bounded_output(output, data), timeout_ms)
      {^port, {:exit_status, code}} -> {:exit, code, output}
    after
      timeout_ms ->
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
      %{summary: %{"failed" => 0}} when code == 0 ->
        %Result{status: :survived, duration_ms: duration_ms}

      %{summary: %{"failed" => failed}, tests: tests} when code != 0 and failed >= 1 ->
        %Result{status: :killed, duration_ms: duration_ms, killing_test: killing_test(tests)}

      _invalid ->
        %Result{status: :error, duration_ms: duration_ms, raw_output: output}
    end
  end

  defp killing_test(tests) do
    tests
    |> Enum.find(&(&1["status"] == "failed"))
    |> case do
      nil -> nil
      test -> "#{test["module"]} #{test["test"]}"
    end
  end

  defp kill_port(port) do
    os_pid = Port.info(port, :os_pid)
    Port.close(port)

    case os_pid do
      {:os_pid, pid} when is_integer(pid) -> System.cmd("kill", ["-9", Integer.to_string(pid)])
      _unknown -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
