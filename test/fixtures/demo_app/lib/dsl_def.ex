defmodule DslDef do
  @moduledoc "Fixture DSL definition module."

  defmacro defadd(name) do
    quote do
      def unquote(name)(a, b), do: a + b
    end
  end

  defmacro defadd_keep(name) do
    quote location: :keep do
      def unquote(name)(a, b), do: a + b
    end
  end
end
