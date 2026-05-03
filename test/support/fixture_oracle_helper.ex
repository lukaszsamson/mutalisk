defmodule Mut.FixtureOracleHelper do
  @moduledoc false

  alias Mut.Oracle
  alias Mut.Oracle.DispatchSite

  @spec golden_oracle(Path.t()) :: Oracle.t()
  def golden_oracle(path \\ Path.expand("test/golden/oracle/demo_app.json")) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(&decode_site/1)
    |> oracle()
  end

  @spec oracle([DispatchSite.t()]) :: Oracle.t()
  def oracle(sites) do
    Enum.reduce(sites, %Oracle{}, fn site, store ->
      key = Oracle.primary_key(site)
      file_line = {site.file, site.line}

      %{
        store
        | sites: store.sites ++ [site],
          by_key: Map.update(store.by_key, key, [site], &(&1 ++ [site])),
          by_file_line: Map.update(store.by_file_line, file_line, [site], &(&1 ++ [site]))
      }
    end)
  end

  defp decode_site(map) do
    %DispatchSite{
      file: map["file"],
      line: map["line"],
      column: map["column"],
      end_line: map["end_line"],
      end_column: map["end_column"],
      env_context: decode_atom(map["env_context"]),
      module: decode_module(map["module"]),
      function: decode_function(map["function"]),
      dispatch_kind: decode_atom(map["dispatch_kind"]),
      resolved_module: decode_module(map["resolved_module"]),
      resolved_name: decode_atom(map["resolved_name"]),
      resolved_arity: map["resolved_arity"],
      event_file: map["event_file"],
      meta: Enum.map(map["meta"] || [], fn [key, value] -> {decode_atom(key), value} end)
    }
  end

  defp decode_function(nil), do: nil
  defp decode_function([name, arity]), do: {decode_atom(name), arity}

  defp decode_module(nil), do: nil
  defp decode_module(module), do: String.to_atom(module)

  defp decode_atom(nil), do: nil
  defp decode_atom(value) when is_binary(value), do: String.to_atom(value)
end
