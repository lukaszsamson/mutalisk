defmodule Mut.WorkCopy do
  @moduledoc "Creates isolated working copies for target projects."

  @spec materialize(Path.t(), term) :: no_return
  def materialize(_project_root, _run_id) do
    raise RuntimeError, "not yet implemented (M2)"
  end
end
