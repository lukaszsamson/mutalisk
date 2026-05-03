defmodule Mix.Tasks.Compile.MutOracle do
  @moduledoc "Mix compiler that registers Mut.Trace before :elixir runs."
  use Mix.Task.Compiler

  alias Mut.Trace
  alias Mut.Trace.Writer

  @impl true
  @spec run([String.t()]) :: {:noop, [Mix.Task.Compiler.Diagnostic.t()]}
  def run(_argv) do
    existing = Code.get_compiler_option(:tracers) || []
    Code.put_compiler_option(:tracers, [Trace | existing])

    {:ok, _pid} = Writer.start_link(jsonl_path: jsonl_path())

    System.at_exit(fn _exit_code ->
      Writer.close_with_count()
    end)

    {:noop, []}
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
