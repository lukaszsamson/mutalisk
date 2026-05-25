defmodule Mix.Tasks.Compile.MutOracle do
  @moduledoc "Mix compiler that registers Mut.Trace before :elixir runs."
  use Mix.Task.Compiler

  alias Mut.Trace
  alias Mut.Trace.Writer

  @impl true
  @spec run([String.t()]) :: {:noop, [Mix.Task.Compiler.Diagnostic.t()]}
  def run(_argv) do
    # Umbrella builds invoke this compiler once per child app in the *same*
    # BEAM, so both side effects must be idempotent: otherwise the Trace
    # tracer would be prepended once per app (duplicate sites) and the named
    # Writer would be re-started (crash) and its JSONL truncated mid-run.
    existing = Code.get_compiler_option(:tracers) || []

    unless Trace in existing do
      Code.put_compiler_option(:tracers, [Trace | existing])
    end

    ensure_writer_started()

    System.at_exit(fn _exit_code ->
      Writer.close_with_count()
    end)

    {:noop, []}
  end

  defp ensure_writer_started do
    case Writer.start_link(jsonl_path: jsonl_path()) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  @spec clean() :: :ok
  def clean do
    :ok
  end

  @impl true
  @spec manifests() :: [Path.t()]
  def manifests do
    []
  end

  defp jsonl_path do
    Path.join(Mix.Project.build_path(), ".mut_oracle.jsonl")
  end
end
