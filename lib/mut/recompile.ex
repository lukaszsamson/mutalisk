defmodule Mut.Recompile do
  @moduledoc "Drives targeted fallback recompilation inside a sandbox."

  alias Mut.Sandbox

  @spec dependents(Mut.MixManifest.t(), [module], [Mut.MixManifest.dep_kind()]) ::
          MapSet.t(Path.t())
  defdelegate dependents(manifest, modules, kinds), to: Mut.MixManifest

  @spec recompile(Sandbox.t(), [Path.t()], [Path.t()], keyword) :: :ok | {:error, term}
  def recompile(%Sandbox{} = sandbox, mutated_files, dependent_files, opts \\ [])
      when is_list(mutated_files) and is_list(dependent_files) and is_list(opts) do
    app = Keyword.fetch!(opts, :app)
    files = Enum.uniq(mutated_files ++ dependent_files)
    args = ["mut.recompile", "--no-deps-check", "--no-archives-check", "--app", app | files]

    case Mut.ChildProcess.run("mix", args, cd: sandbox.path, env: env()) do
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
end
