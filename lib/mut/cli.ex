defmodule Mut.Cli do
  @moduledoc "Parses and normalizes mix mut command-line options."

  alias Mut.Mutator.Defaults

  defmodule Options do
    @moduledoc "Normalized mix mut options."

    @type t :: %__MODULE__{
            files: [String.t()] | nil,
            mutators: [String.t()] | nil,
            enabled_targets: [atom],
            fail_at: float,
            reporters: [atom],
            output_path: String.t(),
            concurrency: pos_integer,
            max_mutants: pos_integer | nil,
            debug_plan: boolean,
            selection: atom,
            test_paths: [String.t()],
            keep_work_copy: boolean,
            worker_type: :mix | :persistent
          }

    defstruct [
      :files,
      :mutators,
      :enabled_targets,
      :fail_at,
      :reporters,
      :output_path,
      :concurrency,
      :max_mutants,
      :debug_plan,
      :selection,
      :test_paths,
      :keep_work_copy,
      :worker_type
    ]
  end

  @known_reporters [:terminal, :stryker_json]
  @known_selection_modes [:static, :coverage, :coverage_with_static_fallback]
  @known_targets [:dispatch, :guard, :module_attribute]
  @known_mutators [
    "arithmetic",
    "comparison_boundary",
    "comparison_negation",
    "boolean",
    "unary_not",
    "guard_comparison_boundary",
    "guard_comparison_negation",
    "guard_type_test",
    "attribute_literal",
    "comparison",
    "guard_comparison"
  ]

  @spec parse([String.t()], keyword) :: {:ok, Options.t()} | {:error, String.t()}
  def parse(argv, config \\ []) when is_list(argv) and is_list(config) do
    case parse_argv(argv) do
      {:ok, parsed} -> normalize(parsed, config)
      {:error, _message} = error -> error
    end
  end

  @spec resolve_mutators([String.t()] | [atom] | nil) :: [module]
  def resolve_mutators(nil), do: Defaults.list()

  def resolve_mutators(names) when is_list(names) do
    mapping = mutator_mapping()

    names
    |> Enum.flat_map(fn name ->
      key = normalize_name(name)

      case Map.fetch(mapping, key) do
        {:ok, modules} -> List.wrap(modules)
        :error -> raise ArgumentError, unknown_mutator_message(key)
      end
    end)
    |> Enum.uniq()
  end

  @spec known_mutator_names() :: [String.t()]
  def known_mutator_names, do: @known_mutators

  defp parse_argv(argv) do
    {parsed, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          files: :string,
          mutators: :string,
          enable: :string,
          fail_at: :float,
          reporters: :string,
          output_path: :string,
          concurrency: :integer,
          max_mutants: :integer,
          selection: :string,
          debug_plan: :boolean,
          keep_work_copy: :boolean,
          worker_type: :string
        ],
        aliases: []
      )

    cond do
      invalid != [] ->
        [{flag, _value} | _] = invalid
        {:error, "unknown option #{flag}; run `mix help mut`"}

      rest != [] ->
        {:error, "unexpected arguments #{Enum.join(rest, " ")}; run `mix help mut`"}

      duplicate_cli_option?(argv) ->
        {:error, "conflicting duplicate flags are not supported; run `mix help mut`"}

      true ->
        {:ok, parsed}
    end
  end

  defp normalize(parsed, config) do
    with {:ok, files} <- files(parsed, config),
         {:ok, mutators} <- mutators(parsed, config),
         {:ok, enabled_targets} <- enabled_targets(parsed, config),
         {:ok, fail_at} <- fail_at(parsed, config),
         {:ok, reporters} <- reporters(parsed, config),
         {:ok, output_path} <- output_path(parsed, config),
         {:ok, concurrency} <- concurrency(parsed, config),
         {:ok, max_mutants} <- max_mutants(parsed),
         {:ok, selection} <- selection(parsed, config),
         {:ok, test_paths} <- test_paths(config),
         {:ok, worker_type} <- worker_type(parsed, config) do
      {:ok,
       %Options{
         files: files,
         mutators: mutators,
         enabled_targets: enabled_targets,
         fail_at: fail_at,
         reporters: reporters,
         output_path: output_path,
         concurrency: concurrency,
         max_mutants: max_mutants,
         debug_plan: Keyword.get(parsed, :debug_plan, false),
         selection: selection,
         test_paths: test_paths,
         keep_work_copy: Keyword.get(parsed, :keep_work_copy, false),
         worker_type: worker_type
       }}
    end
  end

  @known_worker_types [:mix, :persistent]

  defp worker_type(parsed, config) do
    value = Keyword.get(parsed, :worker_type, Keyword.get(config, :worker_type, :mix))
    type = if is_atom(value), do: value, else: target_atom(value)

    if type in @known_worker_types do
      {:ok, type}
    else
      {:error,
       "unknown --worker-type #{inspect(type)}; known: #{Enum.map_join(@known_worker_types, ", ", &Atom.to_string/1)}"}
    end
  end

  defp files(parsed, config) do
    value = Keyword.get(parsed, :files, Keyword.get(config, :files, ["lib"]))
    {:ok, string_list(value)}
  end

  defp mutators(parsed, config) do
    value = Keyword.get(parsed, :mutators, Keyword.get(config, :mutators))

    with {:ok, names} <- maybe_name_list(value),
         :ok <- validate_mutators(names) do
      {:ok, names}
    end
  end

  defp enabled_targets(parsed, config) do
    value =
      Keyword.get(parsed, :enable, Keyword.get(config, :enabled_targets, [:dispatch, :guard]))

    with {:ok, targets} <- atom_list(value, &target_atom/1),
         :ok <- validate_targets(targets) do
      {:ok, targets}
    end
  end

  defp fail_at(parsed, config) do
    value = Keyword.get(parsed, :fail_at, Keyword.get(config, :fail_at, 80.0))

    case number(value) do
      score when is_number(score) and score >= 0 and score <= 100 -> {:ok, score * 1.0}
      _invalid -> {:error, "--fail-at must be between 0 and 100; run `mix help mut`"}
    end
  end

  defp reporters(parsed, config) do
    value = Keyword.get(parsed, :reporters, Keyword.get(config, :reporters, @known_reporters))

    with {:ok, reporters} <- atom_list(value, &reporter_atom/1),
         :ok <- validate_reporters(reporters) do
      {:ok, reporters}
    end
  end

  defp output_path(parsed, config) do
    {:ok,
     Keyword.get(parsed, :output_path, Keyword.get(config, :output_path, "stryker.report.json"))}
  end

  defp concurrency(parsed, config) do
    # v1.6 default: parallel workers, capped at 4 by the M17 milestone.
    # Cap exists because the speedup curve flattens past 4 on the M17
    # reference machine (Decimal: 3.06x at c=4 vs ~3.5x at c=8); each
    # worker BEAM costs ~50-100MB baseline so 4 keeps memory pressure
    # bounded across hardware. Users with more cores can raise it
    # explicitly via `--concurrency 8` or higher.
    default = min(System.schedulers_online(), 4)
    value = Keyword.get(parsed, :concurrency, Keyword.get(config, :concurrency, default))

    case value do
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _invalid -> {:error, "--concurrency must be at least 1; run `mix help mut`"}
    end
  end

  defp max_mutants(parsed) do
    case Keyword.get(parsed, :max_mutants) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _invalid -> {:error, "--max-mutants must be at least 1; run `mix help mut`"}
    end
  end

  defp selection(parsed, config) do
    value = Keyword.get(parsed, :selection, Keyword.get(config, :selection, :static))
    mode = target_atom(value)

    if mode in @known_selection_modes do
      {:ok, mode}
    else
      {:error,
       "unknown --selection mode #{inspect(mode)}; known: #{known(@known_selection_modes)}"}
    end
  end

  defp test_paths(config), do: {:ok, string_list(Keyword.get(config, :test_paths, ["test"]))}

  defp maybe_name_list(nil), do: {:ok, nil}

  defp maybe_name_list(value) do
    {:ok, value |> name_list() |> Enum.map(&normalize_name/1)}
  end

  defp atom_list(value, mapper) do
    {:ok, value |> name_list() |> Enum.map(mapper)}
  end

  defp name_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp name_list(value) when is_list(value), do: value
  defp name_list(value), do: [value]

  defp string_list(nil), do: nil
  defp string_list(value) when is_binary(value), do: [value]
  defp string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp validate_mutators(nil), do: :ok

  defp validate_mutators(names) do
    unknown = Enum.reject(names, &(&1 in @known_mutators))

    if unknown == [] do
      :ok
    else
      {:error, unknown_mutator_message(List.first(unknown))}
    end
  end

  defp validate_targets(targets) do
    unknown = Enum.reject(targets, &(&1 in @known_targets))

    if unknown == [] do
      :ok
    else
      {:error,
       "unknown --enable target #{inspect(List.first(unknown))}; known: #{known(@known_targets)}"}
    end
  end

  defp validate_reporters(reporters) do
    unknown = Enum.reject(reporters, &(&1 in @known_reporters))

    if unknown == [] do
      :ok
    else
      {:error,
       "unknown --reporters value #{inspect(List.first(unknown))}; known: #{known(@known_reporters)}"}
    end
  end

  defp duplicate_cli_option?(argv) do
    argv
    |> Enum.filter(&String.starts_with?(&1, "--"))
    |> Enum.map(&(&1 |> String.trim_leading("--") |> String.split("=", parts: 2) |> List.first()))
    |> Enum.frequencies()
    |> Enum.any?(fn {_key, count} -> count > 1 end)
  end

  defp target_atom(value), do: normalize_name(value) |> String.to_atom()

  defp reporter_atom(value) do
    value
    |> normalize_name()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("-", "_")
  end

  defp mutator_mapping do
    %{
      "arithmetic" => Mut.Mutator.Arithmetic,
      "comparison_boundary" => Mut.Mutator.ComparisonBoundary,
      "comparison_negation" => Mut.Mutator.ComparisonNegation,
      "boolean" => Mut.Mutator.Boolean,
      "unary_not" => Mut.Mutator.UnaryNot,
      "guard_comparison_boundary" => Mut.Mutator.GuardComparisonBoundary,
      "guard_comparison_negation" => Mut.Mutator.GuardComparisonNegation,
      "guard_type_test" => Mut.Mutator.GuardTypeTest,
      "attribute_literal" => Mut.Mutator.AttributeLiteral,
      "comparison" => [Mut.Mutator.ComparisonBoundary, Mut.Mutator.ComparisonNegation],
      "guard_comparison" => [
        Mut.Mutator.GuardComparisonBoundary,
        Mut.Mutator.GuardComparisonNegation
      ]
    }
  end

  defp unknown_mutator_message(name) do
    "unknown mutator #{inspect(name)}; known: #{Enum.join(@known_mutators, ", ")}; run `mix help mut`"
  end

  defp known(values), do: Enum.map_join(values, ", ", &Atom.to_string/1)
end
