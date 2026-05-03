defmodule Mutalisk do
  @moduledoc "Public entry points for Mutalisk."

  @spec active_key() :: term
  defdelegate active_key, to: Mut.Runtime

  @spec set_active(non_neg_integer) :: :ok
  defdelegate set_active(id), to: Mut.Runtime

  @spec get_active() :: non_neg_integer
  defdelegate get_active, to: Mut.Runtime

  @spec clear() :: :ok
  defdelegate clear, to: Mut.Runtime
end
