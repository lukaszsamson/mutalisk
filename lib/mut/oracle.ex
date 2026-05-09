defmodule Mut.Oracle do
  @moduledoc "Stores oracle dispatch sites."

  alias Mut.JSON.OrderedObject
  alias Mut.Oracle.DispatchSite

  defstruct sites: [], by_key: %{}, by_file_line: %{}

  @type key :: {
          Path.t(),
          pos_integer(),
          pos_integer() | nil,
          DispatchSite.dispatch_kind(),
          atom(),
          non_neg_integer()
        }

  @type t :: %__MODULE__{
          sites: [DispatchSite.t()],
          by_key: %{optional(key) => [DispatchSite.t()]},
          by_file_line: %{optional({Path.t(), pos_integer()}) => [DispatchSite.t()]}
        }

  @spec start_link(keyword) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  @spec put_site(DispatchSite.t()) :: :ok
  def put_site(%DispatchSite{} = site) do
    ensure_started()
    Agent.update(__MODULE__, &put_in_store(&1, site))
  end

  @spec lookup_by_key(key) :: [DispatchSite.t()]
  def lookup_by_key(key) do
    ensure_started()
    Agent.get(__MODULE__, &Map.get(&1.by_key, key, []))
  end

  @spec lookup_by_file_line(Path.t(), pos_integer) :: [DispatchSite.t()]
  def lookup_by_file_line(file, line) do
    ensure_started()
    Agent.get(__MODULE__, &Map.get(&1.by_file_line, {file, line}, []))
  end

  @spec dump_json(IO.device() | Path.t()) :: :ok
  def dump_json(io_device) when is_binary(io_device) do
    File.write!(io_device, json_dump())
    :ok
  end

  def dump_json(io_device) do
    IO.write(io_device, json_dump())
    :ok
  end

  @spec load_jsonl(Path.t()) :: {:ok, non_neg_integer} | {:error, term}
  def load_jsonl(path) do
    with {:ok, lines} <- read_lines(path),
         {:ok, sites, count} <- parse_jsonl(lines) do
      ensure_started()

      Agent.update(__MODULE__, fn _store ->
        Enum.reduce(sites, %__MODULE__{}, &put_in_store(&2, &1))
      end)

      {:ok, count}
    end
  end

  @spec snapshot() :: t
  def snapshot do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  @spec primary_key(DispatchSite.t()) :: key
  def primary_key(%DispatchSite{} = site) do
    {site.file, site.line, site.column, site.dispatch_kind, site.resolved_name,
     site.resolved_arity}
  end

  @spec sites_at_line?(t, Path.t(), pos_integer) :: boolean
  def sites_at_line?(%__MODULE__{by_file_line: by_file_line}, file, line) do
    Map.get(by_file_line, {file, line}, []) != []
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, _pid} = start_link([])
      _pid -> :ok
    end
  end

  defp put_in_store(%__MODULE__{} = store, %DispatchSite{} = site) do
    key = primary_key(site)
    file_line = {site.file, site.line}

    %{
      store
      | sites: [site | store.sites],
        by_key: Map.update(store.by_key, key, [site], &[site | &1]),
        by_file_line: Map.update(store.by_file_line, file_line, [site], &[site | &1])
    }
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents |> String.split("\n", trim: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_jsonl(lines) do
    decoded = Enum.map(lines, &Mut.JSON.decode!/1)

    case List.last(decoded) do
      %{"event" => "end", "count" => expected_count} ->
        site_maps = Enum.drop(decoded, -1)

        if expected_count == length(site_maps) do
          {:ok, Enum.map(site_maps, &decode_site/1), expected_count}
        else
          {:error, :count_mismatch}
        end

      _other ->
        {:error, :missing_sentinel}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
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
      meta: decode_meta(map["meta"] || [])
    }
  end

  defp decode_function(nil), do: nil
  defp decode_function([name, arity]), do: {decode_atom(name), arity}

  defp decode_meta(meta) do
    Enum.map(meta, fn
      [key, value] -> {decode_atom(key), value}
      value -> value
    end)
  end

  defp decode_module(nil), do: nil
  defp decode_module(module), do: String.to_atom(module)

  defp decode_atom(nil), do: nil
  defp decode_atom(value) when is_atom(value), do: value
  defp decode_atom(value) when is_binary(value), do: String.to_atom(value)

  defp json_dump do
    ensure_started()

    __MODULE__
    |> Agent.get(& &1.sites)
    |> Enum.sort_by(&sort_key/1)
    |> Enum.map(&canonical_site/1)
    |> Mut.JSON.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort_key(site) do
    {site.file, site.line, site.column || 0, site.dispatch_kind, site.resolved_name,
     site.resolved_arity, site.resolved_module, site.module, site.function, site.env_context,
     site.event_file, site.end_line, site.end_column, site.meta}
  end

  defp canonical_site(site) do
    OrderedObject.new(
      file: site.file,
      line: site.line,
      column: site.column,
      end_line: site.end_line,
      end_column: site.end_column,
      env_context: site.env_context,
      module: site.module,
      function: encode_function(site.function),
      dispatch_kind: site.dispatch_kind,
      resolved_module: site.resolved_module,
      resolved_name: site.resolved_name,
      resolved_arity: site.resolved_arity,
      event_file: site.event_file,
      meta: encode_meta(site.meta)
    )
  end

  defp encode_function(nil), do: nil
  defp encode_function({name, arity}), do: [name, arity]

  defp encode_meta(meta) do
    Enum.map(meta, fn
      {key, value} -> [key, value]
      value -> value
    end)
  end
end
