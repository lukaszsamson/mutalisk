defmodule Mut.Trace do
  @moduledoc "Compiler tracer for oracle dispatch events."

  alias Mut.Oracle.DispatchSite
  alias Mut.Trace.Writer

  @dispatch_kinds [
    :remote_function,
    :remote_macro,
    :local_function,
    :local_macro,
    :imported_function,
    :imported_macro
  ]

  @spec trace(term, Macro.Env.t()) :: :ok
  def trace(event, env) do
    case to_dispatch_site(event, env) do
      nil ->
        :ok

      %DispatchSite{} = site ->
        Writer.put(site)
        :ok
    end
  end

  @spec to_dispatch_site(term, Macro.Env.t()) :: DispatchSite.t() | nil
  def to_dispatch_site({kind, meta, module, name, arity}, env)
      when kind in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    normalize(kind, meta, env, module, name, arity)
  end

  def to_dispatch_site({kind, meta, name, arity}, env)
      when kind in [:local_function, :local_macro] do
    normalize(kind, meta, env, env.module, name, arity)
  end

  def to_dispatch_site(_event, _env) do
    # M2 records only dispatch-shaped events; aliases/modules are observed but unused in v1.
    nil
  end

  defp normalize(kind, meta, env, resolved_module, resolved_name, resolved_arity)
       when kind in @dispatch_kinds do
    event_file = Keyword.get(meta, :file, env.file)

    cond do
      Keyword.get(meta, :generated, false) == true ->
        nil

      event_file != env.file ->
        nil

      generated_context?(meta, env) ->
        nil

      is_nil(Keyword.get(meta, :line)) ->
        nil

      true ->
        %DispatchSite{
          file: relative_file(env.file),
          line: Keyword.fetch!(meta, :line),
          column: Keyword.get(meta, :column),
          end_line: Keyword.get(meta, :end_line),
          end_column: Keyword.get(meta, :end_column),
          env_context: env.context,
          module: env.module,
          function: env.function,
          dispatch_kind: kind,
          resolved_module: resolved_module,
          resolved_name: resolved_name,
          resolved_arity: resolved_arity,
          event_file: relative_file(event_file),
          meta: normalize_meta(meta)
        }
    end
  end

  defp normalize_meta(meta) do
    Enum.map(meta, fn {key, value} -> {key, normalize_meta_value(value)} end)
  end

  defp generated_context?(meta, env) do
    case Keyword.get(meta, :context) do
      nil -> false
      context -> context != env.module
    end
  end

  defp normalize_meta_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&normalize_meta_value/1)
  end

  defp normalize_meta_value(value) when is_list(value) do
    Enum.map(value, &normalize_meta_value/1)
  end

  defp normalize_meta_value(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or
              is_nil(value) do
    value
  end

  defp normalize_meta_value(value) do
    inspect(value)
  end

  defp relative_file(nil), do: nil

  defp relative_file(file) do
    file
    |> Path.expand()
    |> Path.relative_to(project_root())
  end

  # Sites are keyed relative to the project root, not the compiler's cwd.
  # For single-app builds the root *is* the cwd, so paths are byte-identical
  # to the pre-M67 behaviour. For umbrella builds Mix changes cwd into each
  # child app dir during its compile, so without a fixed root every app's
  # files would collide as bare `lib/...`; MUTALISK_PROJECT_ROOT (set by the
  # oracle build to the umbrella root) yields the `apps/<app>/lib/...` keys
  # the schema/fallback engines expect.
  defp project_root, do: System.get_env("MUTALISK_PROJECT_ROOT") || File.cwd!()
end
