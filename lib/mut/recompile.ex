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

  @spec recompile(Sandbox.t(), [Path.t()], [Path.t()], keyword) :: :ok | {:error, term}
  def recompile(%Sandbox{} = sandbox, mutated_files, dependent_files, opts \\ [])
      when is_list(mutated_files) and is_list(dependent_files) and is_list(opts) do
    app = Keyword.fetch!(opts, :app)
    files = Enum.uniq(mutated_files ++ dependent_files)
    ebin = Path.join(["_build", "mut_schema", "lib", app, "ebin"])

    case Mut.ChildProcess.run("elixir", elixir_args(sandbox.path, files, ebin),
           cd: sandbox.path,
           env: env()
         ) do
      {:exit, 0, _output} -> :ok
      {:exit, code, output} -> {:error, {:recompile_failed, code, output}}
      {:error, reason} -> {:error, reason}
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

  defp elixir_args(sandbox_path, files, ebin) do
    pa_flags =
      sandbox_path
      |> Path.join("_build/mut_schema/lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn ebin_path ->
        relative = Path.relative_to(ebin_path, sandbox_path)
        ["-pa", relative]
      end)

    eval =
      "case Kernel.ParallelCompiler.compile_to_path(#{inspect(files)}, #{inspect(ebin)}) " <>
        "do {:ok, _modules, _warnings} -> :ok; " <>
        "{:error, errors, warnings} -> " <>
        "IO.puts(:stderr, \"mut.recompile errors: \#{inspect(errors, limit: :infinity)}\"); " <>
        "IO.puts(:stderr, \"mut.recompile warnings: \#{inspect(warnings, limit: :infinity)}\"); " <>
        "System.halt(1) end"

    pa_flags ++ ["--eval", eval]
  end
end
