defmodule Mut.OpaquePolicy do
  @dialyzer {:no_opaque, [trusted_kernel_control_flow?: 3]}

  @moduledoc """
  Classifies AST call nodes as known-safe forms vs opaque macro
  boundaries. M39 spec section "User Macro Opacity Policy" is
  binding: the walker does NOT expand user macros, and `if` /
  `unless` are trusted ONLY with tracer-oracle proof.

  ## Known-safe forms

    * Declarations: `defmodule`, `def`, `defp`, `defmacro`,
      `defmacrop`, `defguard`, `defguardp`, `alias`, `require`,
      `import`, `@`.
    * Function control flow: `case`, `cond`, `with`, `for`,
      `receive`, `try`, `fn`.
    * Kernel control-flow macros: `if`, `unless` — but ONLY
      with tracer-oracle proof (`trusted_kernel_control_flow?/3`).
    * Operators: `=`, `when`, `and`, `or`, `&&`, `||`, comparisons,
      arithmetic. Descend according to context; dispatch mutators
      continue to use the tracer oracle as the source of truth.
    * Quote forms: `quote`, `unquote`, `unquote_splicing`.
      Boundary; skip subtree by default.

  ## Opaque boundaries

    * Any tracer dispatch site with kind `:local_macro`,
      `:remote_macro`, or `:imported_macro` unless it is in the
      known-safe form table.
    * Any `use` call.
    * Any module-body call that is not a direct known declaration.
    * Any call with a `do` block that is not a known-safe form
      and has no tracer proof that it is a function.
    * Any dynamic `defmodule` target that cannot be resolved
      syntactically.

  Opaque boundaries get `trust_level: :opaque`; descendants get
  `trust_level: :untrusted_descendant`. Mutators must reject
  both by default.
  """

  @known_special_forms ~w(
    defmodule def defp defmacro defmacrop defguard defguardp
    alias require import
    case cond with for receive try fn
    quote unquote unquote_splicing
    = when ^ &
    @
  )a

  @kernel_control_flow ~w(if unless)a

  @quote_forms ~w(quote unquote unquote_splicing)a

  @doc """
  Returns `true` iff the AST call form is a special-form name
  the walker recognises and descends into with explicit per-form
  context discrimination.

  Includes `defguard` / `defguardp` because the walker descends
  into their bodies as guard context. Excludes Kernel
  control-flow macros (`if`, `unless`) — those require tracer
  proof and are classified separately.
  """
  @spec known_special_form?(atom()) :: boolean()
  def known_special_form?(name) when is_atom(name), do: name in @known_special_forms

  @doc """
  Returns `true` iff the name is `if` or `unless`. Treated as a
  separate class because trust requires tracer-oracle proof.
  """
  @spec kernel_control_flow?(atom()) :: boolean()
  def kernel_control_flow?(name) when is_atom(name), do: name in @kernel_control_flow

  @doc """
  Returns `true` iff the form is a quote-class boundary. Subtrees
  are skipped for mutation by default.
  """
  @spec quote_form?(atom()) :: boolean()
  def quote_form?(name) when is_atom(name), do: name in @quote_forms

  @doc """
  Returns `true` iff the call to `if` or `unless` is trusted in
  the current scope/context AND the tracer oracle confirms it
  resolves to `Kernel.if/2` or `Kernel.unless/2`. M39 binding
  rules:

    * The current snapshot must be `scope: :function_body` and
      `context: nil`. In module body it remains opaque
      compile-time code; in guard or match context it is
      unsupported.
    * The tracer oracle must have a matching `:imported_macro` /
      `:remote_macro` site at the call's `{file, line, column}`
      resolving to `Kernel.if/2` or `Kernel.unless/2`. Without
      tracer proof, classify as an opaque macro boundary.

  `macro_index` is a map keyed by `{file, line, column, name,
  arity}` (see `Mut.EnvSnapshot.t/0` doc and the `tracer_macro_index`
  alias in `Mut.EnvWalker`). When `nil` or empty, NO call is
  trusted — the walker conservatively treats `if` / `unless`
  outside tracer scope as opaque.
  """
  @spec trusted_kernel_control_flow?(
          {atom(), keyword(), list()},
          map() | nil,
          Mut.EnvSnapshot.t()
        ) :: boolean()
  def trusted_kernel_control_flow?(_node, _index, %Mut.EnvSnapshot{scope: scope})
      when scope != :function_body,
      do: false

  def trusted_kernel_control_flow?(_node, _index, %Mut.EnvSnapshot{context: context})
      when context != nil,
      do: false

  def trusted_kernel_control_flow?({name, _meta, _args}, _index, _snap)
      when name not in [:if, :unless],
      do: false

  def trusted_kernel_control_flow?(_node, nil, _snap), do: false
  def trusted_kernel_control_flow?(_node, index, _snap) when map_size(index) == 0, do: false

  def trusted_kernel_control_flow?({name, meta, args}, index, snap)
      when name in [:if, :unless] and is_list(args) and is_list(meta) do
    file = snap.file
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)
    arity = length(args)

    case Map.get(index, {file, line, column, name, arity}) do
      %{kind: kind, resolved_module: Kernel, resolved_name: ^name}
      when kind in [:imported_macro, :remote_macro, :local_macro] ->
        true

      _ ->
        false
    end
  end

  def trusted_kernel_control_flow?(_node, _index, _snap), do: false

  @doc """
  Returns the canonical `trust_level` for a non-trusted macro
  call. Always returns `:opaque` for the call node itself.
  Descendants of an opaque node are classified as
  `:untrusted_descendant` by the walker — not by this function.
  """
  @spec opaque_call_trust_level() :: :opaque
  def opaque_call_trust_level, do: :opaque
end
