defmodule Mut.EnvSnapshot do
  @moduledoc """
  Per-AST-node environment classification produced by `Mut.EnvWalker`.

  Designed by M39 (`docs/spikes/M39_env_walker.md`). Captures the
  three classification axes a v2 mutator needs to decide whether a
  node is mutable:

    * `context` — `nil` (normal expression), `:match` (pattern
      position), or `:guard` (guard expression).
    * `scope` — coarse region: `:top_level`, `:module_body`,
      `:attr_value`, `:function_head`, `:function_body`,
      `:macro_definition`, `:quote`, `:opaque_macro`.
    * `trust_level` — source authorship trust: `:trusted` (user-
      authored source the walker classified explicitly),
      `:opaque` (macro boundary the walker refused to expand),
      `:untrusted_descendant` (child of an opaque boundary),
      `:quoted` (inside `quote do ... end`), `:generated` (AST
      node with `generated: true` metadata or a file mismatch).

  `EnvSnapshot` carries *context + trust + binding scope*, not
  module resolution. Alias/import/require resolution is the
  compiler tracer oracle's job (`Mut.Trace` records the compiler's
  `resolved_module/name/arity`); the walker never resolves modules,
  so the snapshot intentionally holds no alias/import/require state.

  ## First-pass mutator gate

  A mutator should treat a snapshot as eligible only when:

      snapshot.scope == :function_body and
      snapshot.context == nil and
      snapshot.trust_level == :trusted

  Anything else routes to fallback diagnostics (`:opaque` /
  `:quoted` / `:generated` / `:untrusted_descendant`) or is
  skipped outright.
  """

  @type context :: nil | :match | :guard
  @type scope ::
          :top_level
          | :module_body
          | :attr_value
          | :function_head
          | :function_body
          | :macro_definition
          | :quote
          | :opaque_macro

  @type trust_level ::
          :trusted
          | :opaque
          | :untrusted_descendant
          | :quoted
          | :generated

  @type ast_path :: [term()]

  @type t :: %__MODULE__{
          file: Path.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          source_span: {non_neg_integer(), non_neg_integer()} | nil,
          ast_path: ast_path(),
          ast_path_hash: binary() | nil,
          module: module() | nil,
          function: {atom(), arity()} | nil,
          context: context(),
          scope: scope(),
          trust_level: trust_level(),
          bound_vars: MapSet.t(atom())
        }

  defstruct file: nil,
            line: nil,
            column: nil,
            source_span: nil,
            ast_path: [],
            ast_path_hash: nil,
            module: nil,
            function: nil,
            context: nil,
            scope: :top_level,
            trust_level: :trusted,
            # M54: local variable names bound and in scope at this node
            # (function params + enclosing clause-head patterns). Does not
            # enter stable-id identity.
            bound_vars: MapSet.new()

  @doc """
  Returns `true` iff the snapshot is eligible for a first-pass
  body-literal mutator. M39 defines this as the canonical gate
  for `Mut.Mutator.StringLiteral` (and any future literal
  mutator added against env walker before pattern/variable
  mutators land).
  """
  @spec body_literal_eligible?(t()) :: boolean()
  def body_literal_eligible?(%__MODULE__{} = snap) do
    snap.scope == :function_body and
      snap.context == nil and
      snap.trust_level == :trusted
  end

  @doc """
  Returns the canonical skip reason for a snapshot that is NOT
  body-literal-eligible. Returns `nil` when the snapshot IS
  eligible. Used by the diagnostics histogram in `Mut.EnvOracle`.
  """
  @spec skip_reason(t()) :: atom() | nil
  def skip_reason(%__MODULE__{} = snap) do
    skip_reason_trust(snap) ||
      skip_reason_span(snap) ||
      skip_reason_context(snap) ||
      skip_reason_scope(snap)
  end

  defp skip_reason_trust(%__MODULE__{trust_level: t}) when t != :trusted, do: t
  defp skip_reason_trust(_), do: nil

  defp skip_reason_span(%__MODULE__{source_span: nil}), do: :missing_span
  defp skip_reason_span(_), do: nil

  defp skip_reason_context(%__MODULE__{context: :match}), do: :match_context
  defp skip_reason_context(%__MODULE__{context: :guard}), do: :guard_context
  defp skip_reason_context(_), do: nil

  defp skip_reason_scope(%__MODULE__{scope: :function_body}), do: nil
  defp skip_reason_scope(%__MODULE__{scope: scope}), do: scope
end
