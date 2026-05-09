defmodule Mut.Plan do
  @moduledoc "Mutation plan consumed by later execution phases."

  alias Mut.JSON.OrderedObject
  alias Mut.Mutant

  @derive {JSON.Encoder, except: [:matched_pairs]}
  @enforce_keys [:schema, :fallback, :skipped]
  defstruct schema: [], fallback: [], skipped: [], invalid: [], matched_pairs: []

  @type skip_reason ::
          :no_applicable_mutator
          | :missing_oracle_site
          | :ambiguous_oracle_match
          | :unsupported_dispatch
          | :unsupported_context
          | :dsl_or_generated
          | :guard_engine_disabled
          | :attribute_engine_disabled
          | :body_literal_engine_disabled

  @type skipped_entry :: %{
          file: Path.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          syntactic_name: atom(),
          reason: skip_reason,
          detail: term()
        }

  @type t :: %__MODULE__{
          schema: [Mutant.t()],
          fallback: [Mutant.t()],
          skipped: [skipped_entry],
          invalid: [Mutant.t()],
          matched_pairs: [{Mut.Oracle.AstCandidate.t(), Mut.Oracle.DispatchSite.t() | nil}]
        }

  @spec finalize(t) :: t
  def finalize(%__MODULE__{} = plan) do
    buckets = Enum.map(plan.schema, &{&1, :schema}) ++ Enum.map(plan.fallback, &{&1, :fallback})

    finalized =
      buckets
      |> Enum.map(fn {mutant, bucket} -> {put_stable_id(mutant), bucket} end)
      |> Enum.sort_by(fn {mutant, _bucket} -> mutant.stable_id end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{mutant, bucket}, id} -> {%{mutant | id: id}, bucket} end)

    %{
      plan
      | schema: bucket(finalized, :schema),
        fallback: bucket(finalized, :fallback),
        skipped: sort_skipped(plan.skipped)
    }
  end

  @spec dump_json(t, IO.device() | Path.t()) :: :ok
  def dump_json(%__MODULE__{} = plan, io_device) when is_binary(io_device) do
    File.write!(io_device, json_dump(plan))
    :ok
  end

  def dump_json(%__MODULE__{} = plan, io_device) do
    IO.write(io_device, json_dump(plan))
    :ok
  end

  @spec dump_json(t) :: String.t()
  def dump_json(%__MODULE__{} = plan), do: json_dump(plan)

  @spec find_by_stable_id(t, String.t()) :: Mutant.t() | nil
  def find_by_stable_id(%__MODULE__{} = plan, stable_id) when is_binary(stable_id) do
    Enum.find(plan.schema ++ plan.fallback ++ plan.invalid, &(&1.stable_id == stable_id))
  end

  defp put_stable_id(%Mutant{} = mutant), do: %{mutant | stable_id: Mut.StableId.compute(mutant)}

  defp bucket(finalized, bucket) do
    finalized
    |> Enum.filter(fn {_mutant, mutant_bucket} -> mutant_bucket == bucket end)
    |> Enum.map(&elem(&1, 0))
  end

  defp json_dump(plan) do
    plan
    |> canonical()
    |> Mut.JSON.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp canonical(%__MODULE__{} = plan) do
    OrderedObject.new(
      schema: Enum.sort_by(plan.schema, & &1.stable_id),
      fallback: Enum.sort_by(plan.fallback, & &1.stable_id),
      invalid: Enum.sort_by(plan.invalid, & &1.stable_id),
      skipped: sort_skipped(plan.skipped)
    )
  end

  defp sort_skipped(skipped) do
    Enum.sort_by(skipped, &{&1.file, &1.line || 0, &1.column || 0, &1.syntactic_name, &1.reason})
  end
end
