defmodule Mut.Recompile do
  @moduledoc """
  Drives targeted fallback recompilation inside a sandbox.

  Production path invokes `elixir --eval` directly (not `mix`) so that
  Mix's deps lock-check does not run. The sandbox is a copy of the
  schema work-copy; for some targets (notably Decimal under the bench
  overlay) `mix.lock` and `_build/mut_schema/deps/<dep>/...` diverge
  enough that Mix's preflight rejects the sandbox with `lock mismatch:
  the dependency is out of date` even when `--no-deps-check` is
  passed. Mix has to load the deps in order to discover the
  `mut.recompile` task (it lives inside the mutalisk dep), and that
  dep loading triggers the lock check before our flag is parsed.

  By skipping Mix entirely we:

    * avoid the lock-check entirely;
    * keep the same compile semantics — `Kernel.ParallelCompiler`
      runs in the spawned BEAM with the sandbox's app + dep ebins
      added to the code path via `-pa`.

  Sandbox.reset's `remove_stray_files` previously deleted dep ebins
  (mutalisk.app, jason.app, ...) from the sandbox because the schema
  baseline only tracks the user app's ebin. The mix-based recompile
  inadvertently restored them on every run; the elixir-direct path
  does not. The sandbox tracking was tightened in the same commit so
  reset only sweeps `_build/<build>/lib/<user_app>/`, leaving sibling
  app ebins intact.
  """

  alias Mut.Sandbox

  @spec dependents(Mut.MixManifest.t(), [module], [Mut.MixManifest.dep_kind()]) ::
          MapSet.t(Path.t())
  defdelegate dependents(manifest, modules, kinds), to: Mut.MixManifest

  @typedoc """
  Why a recompile failed. Each category surfaces differently in reports:

    * `:compile_error` — the patched Elixir source compiled to a
      semantic failure (CompileError: type mismatch, undefined helper
      inside the patched module, function-head pattern violation, etc.).
    * `:parse_error` — the patched bytes did not parse (SyntaxError,
      TokenMissingError, MismatchedDelimiterError). Surfaced separately
      from `:compile_error` for report classification.
    * `:dep_path_error` — compilation reached a module that should
      have been on `-pa` (a sibling module or a dep) but was not
      loadable. Indicates a sandbox materialisation problem rather
      than a faulty mutation.
    * `:unknown` — the elixir invocation failed but the output didn't
      match a known category. Surface verbatim for triage.
  """
  @type error_category :: :compile_error | :parse_error | :dep_path_error | :unknown

  @type result ::
          :ok
          | {:error, {:recompile_failed, error_category(), non_neg_integer(), String.t()}}
          | {:error, term()}

  # M84: transient BEAM-startup signatures observed at `--concurrency 4` (the
  # v1.23 ops note); recover via retry rather than mis-classify as a real
  # compile failure. Never matches on real CompileError/syntax/dep-path output.
  @beam_startup_transients [
    "Failed to load module 'elixir'",
    "Runtime terminating during boot",
    "Crash dump is being written"
  ]

  @spec recompile(Sandbox.t(), [Path.t()], [Path.t()], keyword) :: result
  def recompile(%Sandbox{} = sandbox, mutated_files, dependent_files, opts \\ [])
      when is_list(mutated_files) and is_list(dependent_files) and is_list(opts) do
    default_app = Keyword.fetch!(opts, :app)
    files = Enum.uniq(mutated_files ++ dependent_files)

    case Mut.ChildProcess.run("elixir", elixir_args(sandbox.path, files, default_app),
           cd: sandbox.path,
           env: env(),
           retry_on: @beam_startup_transients,
           max_retries: 2
         ) do
      {:exit, 0, _output} -> :ok
      {:exit, code, output} -> {:error, {:recompile_failed, categorize(output), code, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classify the stderr/stdout from a failed recompile invocation.

  Public so callers (worker, reporters) can re-classify after they have
  reformatted the output, but the typical path is via
  `recompile/4`'s return value.
  """
  @spec categorize(String.t()) :: error_category()
  def categorize(output) when is_binary(output) do
    cond do
      output =~
          ~r/(?:module|function) [A-Za-z0-9_.\/]+ (?:is not loaded|is undefined|could not be found)/ ->
        :dep_path_error

      output =~ ~r/UndefinedFunctionError/ ->
        :dep_path_error

      # Parse-class failures: MismatchedDelimiterError was added in
      # Elixir 1.17 and does not inherit from SyntaxError. Surface all
      # three under `:parse_error` so reports can distinguish them from
      # semantic CompileError.
      output =~ "** (MismatchedDelimiterError)" or output =~ "** (SyntaxError)" or
          output =~ "** (TokenMissingError)" ->
        :parse_error

      output =~ "mut.recompile errors:" or output =~ "** (CompileError)" ->
        :compile_error

      true ->
        :unknown
    end
  end

  @spec env() :: [{String.t(), String.t()}]
  def env do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", "_build/mut_schema"},
      {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
      {"MUTALISK_ROLE", "fallback"},
      {"MUTALISK_PATH", Path.expand(File.cwd!())}
    ]
  end

  @doc false
  # Exposed for testing (asserts the eval bootstraps Mix; see recompile_test).
  #
  # All affected files compile in ONE Kernel.ParallelCompiler.compile pass so
  # the full compile-dependency DAG (across files AND across umbrella apps) is
  # ordered correctly in-process — compiling per-app groups separately loses
  # that ordering and breaks macro/import resolution between dependents (M68).
  # The `:each_module` callback then routes every module's beam to its own
  # app's ebin (`_build/mut_schema/lib/<app>/ebin`), derived from the source
  # path: `apps/<app>/...` for umbrella children, else `default_app`. Without
  # this, cross-app dependents' beams would land in the mutated app's ebin and
  # shadow the real ones at test time.
  def elixir_args(sandbox_path, files, default_app) do
    pa_flags =
      sandbox_path
      |> Path.join("_build/mut_schema/lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn ebin_path ->
        relative = Path.relative_to(ebin_path, sandbox_path)
        ["-pa", relative]
      end)

    # Start the Mix application before compiling. Some projects (e.g. credo)
    # run `Mix.Project`-dependent code at COMPILE time (`use Credo.Check`
    # reaches `Mix.ProjectStack`), which exits with `(exit) ... no process`
    # in this bare `elixir --eval` BEAM unless the Mix server is alive. This
    # caused valid mutants to be mis-reported as compile failures
    # (false-invalids). `Mix.start/0` only boots Mix's agents — it does NOT
    # load the project or run the deps lock-check (the thing this module
    # avoids by skipping `mix`), so it is safe and side-effect-free here.
    # `file` may arrive absolute, so locate the `apps/<app>` segment anywhere
    # in the path (umbrella child); fall back to default_app (single-app).
    # `\#{...}` stays literal so it is interpolated in the child BEAM.
    eval = ~s"""
    Mix.start()
    ebin_of = fn file ->
      app =
        case Enum.drop_while(String.split(file, "/"), &(&1 != "apps")) do
          ["apps", a | _] -> a
          _ -> #{inspect(default_app)}
        end

      Path.join(["_build/mut_schema/lib", app, "ebin"])
    end

    case Kernel.ParallelCompiler.compile(#{inspect(files)},
           each_module: fn file, module, binary ->
             ebin = ebin_of.(file)
             File.mkdir_p!(ebin)
             File.write!(Path.join(ebin, Atom.to_string(module) <> ".beam"), binary)
           end
         ) do
      {:ok, _modules, _warnings} ->
        :ok

      {:error, errors, warnings} ->
        IO.puts(:stderr, "mut.recompile errors: \#{inspect(errors, limit: :infinity)}")
        IO.puts(:stderr, "mut.recompile warnings: \#{inspect(warnings, limit: :infinity)}")
        System.halt(1)
    end
    """

    pa_flags ++ ["--eval", eval]
  end
end
