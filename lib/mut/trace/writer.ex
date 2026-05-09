defmodule Mut.Trace.Writer do
  @moduledoc "Serializes oracle trace events to JSONL."
  use GenServer

  @spec start_link(jsonl_path: Path.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :jsonl_path), name: __MODULE__)
  end

  @spec put(Mut.Oracle.DispatchSite.t()) :: :ok
  def put(%Mut.Oracle.DispatchSite{} = site) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:put, site})
    end
  end

  @spec close_with_count() :: :ok
  def close_with_count do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :close_with_count, :infinity)
    end
  end

  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.stop(__MODULE__, :normal, :infinity)
    end
  end

  @impl true
  def init(jsonl_path) do
    File.mkdir_p!(Path.dirname(jsonl_path))
    File.rm(jsonl_path)
    file = File.open!(jsonl_path, [:append, :utf8])

    {:ok, %{file: file, count: 0}}
  end

  @impl true
  def handle_cast({:put, %Mut.Oracle.DispatchSite{} = site}, state) do
    IO.write(state.file, [Mut.JSON.encode!(site), ?\n])
    {:noreply, %{state | count: state.count + 1}}
  end

  @impl true
  def handle_call(:close_with_count, _from, state) do
    IO.write(state.file, ~s({"event":"end","count":#{state.count}}\n))
    File.close(state.file)

    {:stop, :normal, :ok, %{state | file: nil}}
  end

  @impl true
  def terminate(_reason, %{file: nil}) do
    :ok
  end

  def terminate(_reason, %{file: file}) do
    File.close(file)
    :ok
  end

  def terminate(_reason, _state) do
    :ok
  end
end
