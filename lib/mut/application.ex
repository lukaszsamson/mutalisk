defmodule Mut.Application do
  @moduledoc "Application start callback; reads MUT_ACTIVE into :persistent_term."
  use Application

  @impl true
  @spec start(Application.start_type(), term) :: Supervisor.on_start()
  def start(_type, _args) do
    System.get_env("MUT_ACTIVE")
    |> parse_active()
    |> Mut.Runtime.set_active()

    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Sup)
  end

  defp parse_active(nil), do: 0
  defp parse_active(""), do: 0

  defp parse_active(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {id, ""} when id >= 0 ->
        id

      _invalid ->
        IO.puts(:stderr, "[mutalisk] invalid MUT_ACTIVE=#{inspect(value)}; using 0")
        0
    end
  end
end
