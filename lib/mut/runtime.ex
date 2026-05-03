defmodule Mut.Runtime do
  @moduledoc "Runtime mutant selector; thin :persistent_term wrapper."

  @spec active_key() :: term
  def active_key, do: {__MODULE__, :active_mutant}

  @spec set_active(non_neg_integer) :: :ok
  def set_active(id) when is_integer(id) and id >= 0 do
    :persistent_term.put(active_key(), id)
  end

  @spec get_active() :: non_neg_integer
  def get_active do
    :persistent_term.get(active_key(), 0)
  end

  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(active_key())
    :ok
  end
end
