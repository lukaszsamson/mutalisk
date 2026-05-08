defmodule AppStartCallback.Repo do
  @moduledoc false

  @table :app_start_callback_kv

  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  def double(n) when is_integer(n), do: n + n
end
