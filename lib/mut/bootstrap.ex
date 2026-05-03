defmodule Mut.Bootstrap do
  @moduledoc "Bootstrap helpers loaded into child Mix BEAMs."

  @type role :: :oracle | :schema | :worker | :fallback

  @spec role() :: role | nil
  def role do
    case System.get_env("MUTALISK_ROLE") do
      "oracle" -> :oracle
      "schema" -> :schema
      "worker" -> :worker
      "fallback" -> :fallback
      _unset_or_unknown -> nil
    end
  end
end
