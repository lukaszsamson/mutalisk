defmodule Mutalisk do
  @moduledoc """
  Public runtime helpers for Mutalisk.

  Most users interact with Mutalisk through `mix mut`. This module exists for
  diagnostics, tests, and advanced integrations that need to inspect or set the
  active mutant id in the current BEAM.

  The active id is stored in VM-global `:persistent_term`. If you set it
  manually in tests or tools, use `try ... after Mutalisk.clear() end` so the
  mutated state does not leak to other processes in the same VM.
  """

  @doc """
  Returns the `:persistent_term` key used to store the active mutant id.

  Instrumented code reads this key to decide whether to execute original or
  mutated code. Normal users should prefer `get_active/0`.
  """
  @spec active_key() :: term
  defdelegate active_key, to: Mut.Runtime

  @doc """
  Sets the active mutant id for the current BEAM.

  Passing `0` selects the original, unmutated behavior. Mutant worker processes
  set this automatically; direct calls are primarily useful in diagnostics and
  focused tests.

  This writes VM-global `:persistent_term`, so every instrumented module in the
  VM observes the new id until another `set_active/1` call or `clear/0`.
  """
  @spec set_active(non_neg_integer) :: :ok
  defdelegate set_active(id), to: Mut.Runtime

  @doc """
  Returns the active mutant id for the current BEAM.

  The default is `0`, meaning no mutant is active. The value is VM-global, not
  process-local.
  """
  @spec get_active() :: non_neg_integer
  defdelegate get_active, to: Mut.Runtime

  @doc """
  Clears the active mutant id from `:persistent_term`.

  After clearing, `get_active/0` returns `0` again for every process in the VM.
  """
  @spec clear() :: :ok
  defdelegate clear, to: Mut.Runtime
end
