defmodule Mix.Tasks.Mut.Recompile do
  @moduledoc "Mix task for targeted fallback recompilation."
  use Mix.Task

  @impl true
  @spec run([String.t()]) :: no_return
  def run(_argv) do
    raise RuntimeError, "not yet implemented (M10)"
  end
end
