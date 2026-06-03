defmodule Mix.Tasks.Mut.Recompile do
  @moduledoc false
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, files, _invalid} =
      OptionParser.parse(argv,
        strict: [
          app: :string,
          ebin: :string,
          no_deps_check: :boolean,
          no_archives_check: :boolean
        ]
      )

    app = Keyword.fetch!(opts, :app)
    files = validate_files!(files)

    ebin =
      Keyword.get_lazy(opts, :ebin, fn ->
        Path.join([Mix.Project.build_path(), "lib", app, "ebin"])
      end)

    case Kernel.ParallelCompiler.compile_to_path(files, ebin) do
      {:ok, _modules, _warnings} -> :ok
      {:error, errors, _warnings} -> Mix.raise("mut.recompile failed: #{inspect(errors)}")
    end
  end

  defp validate_files!(files) do
    Enum.map(files, fn file ->
      if Path.type(file) == :absolute or ".." in Path.split(file) do
        Mix.raise("mut.recompile expects sandbox-relative source paths, got: #{file}")
      end

      file
    end)
  end
end
