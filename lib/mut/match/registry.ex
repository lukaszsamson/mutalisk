defmodule Mut.Match.Registry do
  @moduledoc "Stores match compatibility mutators."

  @key {__MODULE__, :mutators}

  @spec register(mutator :: module) :: :ok
  def register(mutator) when is_atom(mutator) do
    Process.put(@key, Enum.uniq([mutator | list()]))
    :ok
  end

  @spec list() :: [module]
  def list do
    case Process.get(@key) do
      nil -> [Mut.Match.AlwaysCompatible]
      mutators -> mutators
    end
  end

  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end
end
