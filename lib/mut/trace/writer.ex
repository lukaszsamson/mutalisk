defmodule Mut.Trace.Writer do
  @moduledoc "Serializes oracle trace events to JSONL."

  @spec start_link(keyword) :: no_return
  def start_link(_opts) do
    raise RuntimeError, "not yet implemented (M2)"
  end
end
