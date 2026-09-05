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

    retried =
      if retry? and result.status == :error do
        case Sandbox.reset(sandbox) do
          :ok ->
            do_run_schema(
              sandbox,
              mutant_id,
              test_files,
              Keyword.put(opts, :retry_on_error, false)
            )

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

    retried |> settle_priv(sandbox) |> relativize_killer(sandbox)
  end

  # T26: a schema run never dirties sources or beams (the mutant is selected at
  # runtime via MUT_ACTIVE), but its TESTS can still write under `priv/` —
  # SQLite/Mnesia files, generated assets — which the next mutant on this
  # sandbox would then observe. `reset_priv/1` restores just that (a stat-only
  # walk of `priv/`), so the cheap part of a reset runs here while the
  # expensive beam hashing stays on the fallback path. A failed reset is
  # retried once (a test's background process may still be writing); if it
  # still fails the verdict is downgraded to `:error` rather than raising —
  # raising here would replace a valid verdict and abort the whole run.
  defp settle_priv(%Result{} = result, sandbox) do
    with {:error, _first} <- Sandbox.reset_priv(sandbox),
         {:error, reason} <- Sandbox.reset_priv(sandbox) do
      %Result{
        status: :error,
        duration_ms: result.duration_ms,
        raw_output:
          "sandbox #{sandbox.id} priv/ could not be reset after the schema run " <>
            "(would contaminate later mutants): #{inspect(reason)}\n#{result.raw_output}"
      }
    else
      :ok -> result
    end
  end

  # ExUnit reports the failing test's file as an absolute path inside the
  # per-run sandbox; the report and the incremental history need it relative
  # to the project (it must line up with `covering_tests` and outlive the
  # sandbox).
  defp relativize_killer(%Result{killing_test_file: file} = result, %Sandbox{path: root})
       when is_binary(file) do
    if Path.type(file) == :absolute,
      do: %Result{result | killing_test_file: Path.relative_to(file, root)},
      else: result
  end

  defp relativize_killer(result, _sandbox), do: result

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
           :ok <-
             Mut.Recompile.recompile(sandbox, [patch.file], dependents,
               app: app(opts),
               app_context: Keyword.get(opts, :app_context)
             ) do
        sandbox |> spawn_fallback_mix(test_files, opts, started) |> relativize_killer(sandbox)
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

  @spec args([String.t()], pos_integer(), keyword()) :: [String.t()]
  def args(test_files, test_timeout_ms \\ @default_test_timeout_ms, opts \\ [])
      when is_list(test_files) and is_integer(test_timeout_ms) and test_timeout_ms > 0 and
             is_list(opts) do
    args =
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

    case Keyword.get(opts, :umbrella_app) do
      app when is_binary(app) -> ["do", "--app", app | args]
      _ -> args
    end
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
            args(test_files, test_timeout(opts), opts),
            sandbox.path,
            env(mutant_id)
          )

        # T32: snapshot the os_pid right after open — a wrapper `mix` (asdf/mise
        # shim, not exec'd) can have already exited by the time the timeout path
        # runs cleanup, at which point Port.info/2 returns nil even though the
        # real beam.smp descendant is still alive.
        os_pid = port_os_pid(port)

        port
        |> collect(os_pid, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
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
            args(test_files, test_timeout(opts), opts),
            sandbox.path,
            fallback_env()
          )

        os_pid = port_os_pid(port)

        port
        |> collect(os_pid, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
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
      #
      # The manifest lives under the OTP app name (`_build/<env>/lib/<app>`)
      # while the sources it records are re-prefixed with the child's
      # DIRECTORY name so they line up with mutant file paths
      # (`<apps_path>/<dir>/lib/...`). Conflating the two makes every
      # cross-app dependent lookup miss on umbrellas whose directory name
      # differs from `:app` (B4).
      sandbox.path
      |> manifest_entries()
      |> Mut.MixManifest.read_combined(Mut.Umbrella.apps_path_name(sandbox.path))
    else
      sandbox
      |> manifest_path(app(opts))
      |> Mut.MixManifest.read()
    end
  end

  @doc false
  # Exposed for testing. `{child directory, manifest path under the OTP app}`
  # for every umbrella child, sorted for a deterministic merge order.
  @spec manifest_entries(Path.t()) :: [{String.t(), Path.t()}]
  def manifest_entries(sandbox_path) do
    sandbox_path
    |> Mut.Umbrella.app_map()
    |> Enum.sort()
    |> Enum.map(fn {dir, otp_app} -> {dir, manifest_path(sandbox_path, otp_app)} end)
  end

  defp manifest_path(%Sandbox{path: path}, app), do: manifest_path(path, app)

  defp manifest_path(sandbox_path, app) when is_binary(sandbox_path) do
    Path.join([sandbox_path, "_build/mut_schema/lib", app, ".mix/compile.elixir"])
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
    # T32: launch through Mut.ProcessTree's group launcher so the mutant BEAM
    # lands in its own process group and can be reaped as a group even after a
    # non-exec `mix` shim has exited. The launcher `exec`s, so :exit_status,
    # :stderr_to_stdout, :cd and :env all still describe the real child.
    {executable, spawn_args} = Mut.ProcessTree.spawn_command(mix_path, args)

    Port.open({:spawn_executable, executable}, [
      {:args, spawn_args},
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
  defp collect(port, os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, "", deadline)
  end

  # T24: the mutant's output is arbitrary bytes (a truncated latin-1 log line, a
  # binary payload, a sequence cut by an OOM kill). It ends up verbatim in
  # `Result.raw_output` and from there in the Stryker JSON report, whose encoder
  # rejects invalid UTF-8 — one stray byte would crash the final write and
  # destroy the whole run. Scrub once, here at capture, on the *whole*
  # accumulated output so codepoints split across port chunks stay intact.
  defp collect(port, os_pid, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, os_pid, bounded_output(output, data), deadline)
      {^port, {:exit_status, code}} -> {:exit, code, Mut.Text.scrub_utf8(output)}
    after
      remaining ->
        kill_port(port, os_pid)
        drain_port_messages(port)
        {:timeout, Mut.Text.scrub_utf8(output)}
    end
  end

  defp port_os_pid(port), do: Mut.ProcessTree.identify(port)

  # T31: after closing a timed-out port, drain any {port, {:data, _}} /
  # {port, {:exit_status, _}} messages already queued for it in this worker's
  # (long-lived, one-per-slot) mailbox so repeated timeouts don't accumulate
  # stale junk for a later unrelated `receive` to scan past. `after 0` only
  # drains what's already queued — it never waits for new messages.
  defp drain_port_messages(port) do
    receive do
      {^port, {:data, _data}} -> drain_port_messages(port)
      {^port, {:exit_status, _code}} -> drain_port_messages(port)
      {:EXIT, ^port, _reason} -> drain_port_messages(port)
    after
      0 -> :ok
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
      # Advance to a valid UTF-8 boundary so JSON encoding never sees a broken grapheme.
      marker <> utf8_align(binary_part(combined, byte_size(combined), -keep_bytes))
    end
  end

  # Drop at most 3 leading UTF-8 continuation bytes (0x80–0xBF) that result from
  # slicing at an arbitrary byte offset inside a multi-byte codepoint.
  defp utf8_align(<<b, rest::binary>>) when b >= 0x80 and b <= 0xBF, do: utf8_align(rest)
  defp utf8_align(binary), do: binary

  defp classify({:timeout, output}, duration_ms) do
    %Result{status: :timeout, duration_ms: duration_ms, raw_output: output}
  end

  defp classify({:exit, code, output}, duration_ms) do
    case Formatter.parse_output(output) do
      # R9/T30: zero tests *executed* (tag excludes / path filters matched
      # nothing, or every selected test was skipped/excluded) is NOT a surviving
      # mutant — no test had the chance to detect it. Classifying it `:survived`
      # manufactures false survivors that imply test-suite gaps that don't
      # exist. Note that `:no_coverage` still counts as UNDETECTED in the
      # documented score (`Mut.Metrics.score/4` puts it in the denominator, like
      # `:survived`); the distinction is diagnostic, not a score change. `total`
      # counts skipped and excluded tests too, so it cannot answer this on its
      # own — `ran` can.
      %{summary: %{"failed" => 0} = summary} when code == 0 ->
        if ran_count(summary) == 0 do
          %Result{status: :no_coverage, duration_ms: duration_ms}
        else
          %Result{status: :survived, duration_ms: duration_ms}
        end

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

  # Tests that actually executed. The formatter emits `ran` directly; fall back
  # to `total - skipped` so an older/partial summary still classifies correctly
  # (`total` alone counts skipped and excluded tests).
  defp ran_count(%{"ran" => ran}) when is_integer(ran), do: ran

  defp ran_count(summary) do
    total = Map.get(summary, "total", 0)
    skipped = Map.get(summary, "skipped", 0)

    max(total - skipped, 0)
  end

  defp killing_test(nil), do: nil
  defp killing_test(test), do: "#{test["module"]} #{test["test"]}"

  # Tree-kill the spawned process (not just the immediate os_pid): under a
  # version manager / wrapper `mix`, the immediate child forks the real BEAM,
  # so `kill -9 <immediate>` orphans the (often infinite-looping) mutant VM on
  # the timeout path. Shared with Mut.ChildProcess via Mut.ProcessTree.
  defp kill_port(port, os_pid), do: Mut.ProcessTree.kill_port(port, os_pid)

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
