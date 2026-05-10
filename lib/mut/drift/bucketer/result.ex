defmodule Mut.Drift.Bucketer.Result do
  @moduledoc """
  Accumulator + final-shape struct for `Mut.Drift.Bucketer.analyze/3`.

  Tracks four primary partitions plus per-bucket counts for drift.
  Designed to be folded over with the `add_*` helpers; the resulting
  struct is what `Mix.Tasks.Mut.Drift` formats into a per-target
  table.
  """

  defstruct target: nil,
            agree_killed: [],
            agree_survived: [],
            agree_other: %{},
            drift: [],
            mix_only: [],
            persistent_only: [],
            buckets: %{
              mox_class: 0,
              ecto_warm_state: 0,
              ecto_false_kill: 0,
              gettext_class: 0,
              parse_class: 0,
              timeout_flap: 0,
              unclassified: 0
            }

  @type drift_entry :: %{
          id: String.t(),
          mix_status: String.t(),
          persistent_status: String.t(),
          bucket: atom()
        }

  @type t :: %__MODULE__{
          target: String.t() | nil,
          agree_killed: [String.t()],
          agree_survived: [String.t()],
          agree_other: %{optional(String.t()) => non_neg_integer()},
          drift: [drift_entry()],
          mix_only: [String.t()],
          persistent_only: [String.t()],
          buckets: %{required(atom()) => non_neg_integer()}
        }

  @spec new(String.t() | nil) :: t()
  def new(target), do: %__MODULE__{target: target}

  @spec add_agree_killed(t(), String.t()) :: t()
  def add_agree_killed(result, id), do: %{result | agree_killed: [id | result.agree_killed]}

  @spec add_agree_survived(t(), String.t()) :: t()
  def add_agree_survived(result, id), do: %{result | agree_survived: [id | result.agree_survived]}

  @spec add_agree_other(t(), String.t(), String.t()) :: t()
  def add_agree_other(result, _id, status) do
    %{result | agree_other: Map.update(result.agree_other, status, 1, &(&1 + 1))}
  end

  @spec add_mix_only(t(), String.t()) :: t()
  def add_mix_only(result, id), do: %{result | mix_only: [id | result.mix_only]}

  @spec add_persistent_only(t(), String.t()) :: t()
  def add_persistent_only(result, id),
    do: %{result | persistent_only: [id | result.persistent_only]}

  @spec add_drift(t(), String.t(), String.t(), String.t(), atom()) :: t()
  def add_drift(result, id, mix_status, persistent_status, bucket) do
    entry = %{
      id: id,
      mix_status: mix_status,
      persistent_status: persistent_status,
      bucket: bucket
    }

    buckets = Map.update(result.buckets, bucket, 1, &(&1 + 1))
    %{result | drift: [entry | result.drift], buckets: buckets}
  end

  @doc "Total mutants that appear in either report."
  @spec total(t()) :: non_neg_integer()
  def total(result) do
    length(result.agree_killed) +
      length(result.agree_survived) +
      Enum.sum(Map.values(result.agree_other)) +
      length(result.drift) +
      length(result.mix_only) +
      length(result.persistent_only)
  end

  @doc "Total drifting mutants (sum of bucket counts)."
  @spec drift_total(t()) :: non_neg_integer()
  def drift_total(result), do: length(result.drift)

  @doc "Drift rate as percentage (0..100)."
  @spec drift_rate(t()) :: float()
  def drift_rate(result) do
    case total(result) do
      0 -> 0.0
      n -> Float.round(drift_total(result) / n * 100, 2)
    end
  end

  @doc "Unclassified rate as percentage of total drift (0..100)."
  @spec unclassified_rate(t()) :: float()
  def unclassified_rate(result) do
    case drift_total(result) do
      0 -> 0.0
      n -> Float.round(Map.get(result.buckets, :unclassified, 0) / n * 100, 2)
    end
  end
end
