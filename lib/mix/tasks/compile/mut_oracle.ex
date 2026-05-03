defmodule Mix.Tasks.Compile.MutOracle do
  @moduledoc "Mix compiler that registers Mut.Trace before :elixir runs."
  use Mix.Task.Compiler

  @impl true
  @spec run([String.t()]) :: no_return
  def run(_argv) do
    raise RuntimeError, "not yet implemented (M2)"
  end

  @impl true
  @spec clean() :: no_return
  def clean do
    raise RuntimeError, "not yet implemented (M2)"
  end

  @impl true
  @spec manifests() :: no_return
  def manifests do
    raise RuntimeError, "not yet implemented (M2)"
  end
end
