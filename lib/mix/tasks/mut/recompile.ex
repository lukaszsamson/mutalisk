defmodule Mix.Tasks.Mut.Recompile do
  @moduledoc "Mix task for targeted fallback recompilation."
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, files, _invalid} = OptionParser.parse(argv, strict: [app: :string, ebin: :string])
    app = Keyword.fetch!(opts, :app)

    ebin =
      Keyword.get_lazy(opts, :ebin, fn ->
        Path.join([Mix.Project.build_path(), "lib", app, "ebin"])
      end)

    case Kernel.ParallelCompiler.compile_to_path(files, ebin) do
      {:ok, _modules, _warnings} -> :ok
      {:error, errors, _warnings} -> Mix.raise("mut.recompile failed: #{inspect(errors)}")
    end
  end
end
