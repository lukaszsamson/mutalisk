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
            test_paths: [String.t()] | nil,
            keep_work_copy: boolean,
            test_timeout_ms: pos_integer,
            suite_timeout_ms: pos_integer | nil,
            exclude: [Regex.t()] | nil,
            incremental: boolean,
            since: String.t() | nil,
            history_path: String.t() | nil,
            coverage_timeout_ms: pos_integer | nil
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
      :test_timeout_ms,
      :suite_timeout_ms,
      :exclude,
      :since,
      :history_path,
      :coverage_timeout_ms,
      incremental: false
    ]
  end

  # Default reporters (when neither --reporters nor config sets them). HTML and
  # GitHub Actions are opt-in only — valid but never default.
  @default_reporters [:terminal, :stryker_json]
  @known_reporters [:terminal, :stryker_json, :html, :github_actions]
  @known_selection_modes [:static, :coverage, :coverage_with_static_fallback]
  @known_targets [
    :dispatch,
    :guard,
    :module_attribute,
    :body_literal,
    :env_walker,
    :pattern_literal,
    :variable,
    :pattern_shape,
    :conditional,
    :statement_delete,
    :clause_delete,
    :guard_boolean,
    :pipeline_drop,
    :map_update_drop,
    :receive_timeout
  ]
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
    "integer_literal",
    "boolean_literal",
    "string_literal",
    "float_literal",
    "nil_literal",
    "atom_literal",
    "collection_empty",
    "variable_replace",
    "variable_to_literal",
    "concat_operator",
    "bitwise_operator",
    "membership",
    "pin",
    "function_replace",
    "negate_conditional",
    "statement_delete",
    "clause_delete",
    "guard_boolean",
    "pipeline_drop_stage",
    "map_update_drop",
    "receive_timeout",
    "comparison",
    "guard_comparison",
    "body_literal"
  ]

  # M48 tier model. With neither --enable nor --mutators, the default plan
  # runs the v1 dispatch+guard mutators PLUS AtomLiteral (M46 default_on
  # decision): the env walker runs by default but only AtomLiteral is
  # active. String/Float/Nil/Collection stay opt-in. Any explicit --enable
  # selects the target-selectable set; --mutators can also name explicit-only
  # mutators such as VariableToLiteral.
  # @default_on_mutators mirrors `Mut.Mutator.Defaults.default_on/0` as CLI
  # names (a test asserts they resolve to the same modules).
  @default_on_mutators ~w(
    arithmetic comparison_boundary comparison_negation boolean unary_not
    guard_comparison_boundary guard_comparison_negation guard_type_test
    atom_literal integer_literal concat_operator pin function_replace
  )
  # M83: :pattern_shape moves into the default enabled targets so Pin (the only
  # graduated :pattern_shape mutator) fires without `--enable pattern_shape`.
  @default_enabled_targets [:dispatch, :guard, :env_walker, :pattern_shape]
  @min_explicit_concurrency_ceiling 16
  @known_config_keys [
    :files,
    :test_paths,
    :mutators,
    :enabled_targets,
    :selection,
    :fail_at,
    :concurrency,
    :test_timeout_ms,
    :suite_timeout_ms,
    :reporters,
    :output_path,
    :exclude,
    :max_mutants,
    :since,
    :incremental,
    :history_path,
    :coverage_timeout_ms
  ]
  @strict_switches [
    files: [:string, :keep],
    test_paths: [:string, :keep],
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
    test_timeout_ms: :integer,
    suite_timeout_ms: :integer,
    incremental: :boolean,
    since: :string
  ]
  @known_switch_names @strict_switches |> Keyword.keys() |> Enum.map(&Atom.to_string/1)

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
      resolve_mutator_modules(mapping, key)
    end)
    |> Enum.uniq()
  end

  defp resolve_mutator_modules(mapping, key) do
    case Map.fetch(mapping, key) do
      {:ok, modules} ->
        List.wrap(modules)

      :error ->
        resolve_mutator_modules_by_report_name(mapping, key)
    end
  end

  defp resolve_mutator_modules_by_report_name(mapping, key) do
    # The terminal/HTML reports display each mutator by its CamelCase module
    # name. Accept that copied name before giving up.
    case Map.fetch(mapping, Macro.underscore(key)) do
      {:ok, modules} -> List.wrap(modules)
      :error -> raise ArgumentError, unknown_mutator_message(key)
    end
  end

  @spec known_mutator_names() :: [String.t()]
  def known_mutator_names, do: @known_mutators

  defp parse_argv(argv) do
    argv = expand_multi_file_args(argv)

    {parsed, rest, invalid} =
      OptionParser.parse(argv, strict: @strict_switches, aliases: [])

    cond do
      invalid != [] ->
        [{flag, value} | _] = invalid
        invalid_option_error(flag, value)

      rest != [] ->
        {:error, "unexpected arguments #{Enum.join(rest, " ")}; run `mix help mut`"}

      duplicate_cli_option?(argv) ->
        {:error, "conflicting duplicate flags are not supported; run `mix help mut`"}

      true ->
        {:ok, parsed}
    end
  end

  @multi_value_flags ["--files", "--test-paths"]

  # OptionParser's strict mode reports both "this flag doesn't exist" and "this
  # flag exists but its value is missing" (e.g. `--output-path` at end of argv,
  # or immediately followed by another flag) the same way: `{flag, nil}` in the
  # invalid list. Distinguish them by checking whether the flag name is one of
  # ours (T47) — an unknown flag with a value attached (`--bogus 1`) also comes
  # back as `{"--bogus", nil}`, so a known-name match is the only reliable signal.
  defp invalid_option_error(flag, nil) do
    bare = String.trim_leading(flag, "--")

    # A switch name containing "_" is always invalid per OptionParser (switches
    # may only use "-"), so it is never a "missing value" case — treat it as
    # unknown rather than mislabeling it as one of our known switches.
    if String.contains?(bare, "_") do
      {:error, "unknown option #{flag}; run `mix help mut`"}
    else
      normalized = String.replace(bare, "-", "_")

      if normalized in @known_switch_names do
        {:error, "missing value for #{flag}; run `mix help mut`"}
      else
        {:error, "unknown option #{flag}; run `mix help mut`"}
      end
    end
  end

  # OptionParser reports a KNOWN flag with an unparsable value as
  # `{flag, value}` too; say so instead of calling the flag unknown.
  defp invalid_option_error(flag, value) do
    normalized = flag |> String.trim_leading("--") |> String.replace("-", "_")

    if normalized in @known_switch_names do
      {:error, "invalid value #{inspect(value)} for #{flag}; run `mix help mut`"}
    else
      {:error, "unknown option #{flag}; run `mix help mut`"}
    end
  end

  defp expand_multi_file_args(argv), do: expand_multi_file_args(argv, [])

  defp expand_multi_file_args([], acc), do: Enum.reverse(acc)

  defp expand_multi_file_args([flag | rest], acc) when flag in @multi_value_flags do
    {files, rest} = Enum.split_while(rest, &not_option?/1)

    case files do
      [] ->
        expand_multi_file_args(rest, [flag | acc])

      [_one | _] ->
        expanded =
          files
          |> Enum.reverse()
          |> Enum.flat_map(&[&1, flag])

        expand_multi_file_args(rest, expanded ++ acc)
    end
  end

  defp expand_multi_file_args([arg | rest], acc), do: expand_multi_file_args(rest, [arg | acc])

  defp not_option?(arg), do: not String.starts_with?(arg, "-")

  defp normalize(parsed, config) do
    with :ok <- validate_config_keys(config),
         {:ok, files} <- files(parsed, config),
         {:ok, mutators} <- mutators(parsed, config),
         {:ok, enabled_targets} <- enabled_targets(parsed, config),
         {:ok, fail_at} <- fail_at(parsed, config),
         {:ok, reporters} <- reporters(parsed, config),
         {:ok, output_path} <- output_path(parsed, config),
         {:ok, concurrency} <- concurrency(parsed, config),
         {:ok, max_mutants} <- max_mutants(parsed, config),
         {:ok, selection} <- selection(parsed, config),
         {:ok, test_paths} <- test_paths(parsed, config),
         {:ok, test_timeout_ms} <- test_timeout_ms(parsed, config),
         {:ok, suite_timeout_ms} <- suite_timeout_ms(parsed, config),
         {:ok, coverage_timeout_ms} <- coverage_timeout_ms(config),
         {:ok, exclude} <- exclude(config),
         {:ok, incremental} <- incremental(parsed, config),
         {:ok, since} <- since(parsed, config),
         {:ok, history_path} <- history_path(config) do
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
         test_timeout_ms: test_timeout_ms,
         suite_timeout_ms: suite_timeout_ms,
         exclude: exclude,
         incremental: incremental,
         since: since,
         history_path: history_path,
         coverage_timeout_ms: coverage_timeout_ms
       }}
    end
  end

  # `incremental` must be a real boolean. A config string like "false" is truthy
  # and would silently enable reuse (Exploratory #16). CLI `--incremental` is
  # always boolean (OptionParser); config wins fallback per the T10 rule.
  defp incremental(parsed, config) do
    case Keyword.get(parsed, :incremental, Keyword.get(config, :incremental, false)) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, "incremental must be true or false; got #{inspect(other)}"}
    end
  end

  # `since` is a git ref. Must be a non-empty string (or nil). A non-string value
  # otherwise reaches `System.cmd/3` and crashes with a raw ArgumentError
  # (Exploratory #20, #28). CLI flag wins, config is the fallback (T10).
  defp since(parsed, config) do
    case Keyword.get(parsed, :since, Keyword.get(config, :since)) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, "since must be a non-empty string git ref; got #{inspect(value)}"}
        else
          {:ok, trimmed}
        end

      other ->
        {:error, "since must be a non-empty string git ref; got #{inspect(other)}"}
    end
  end

  # Config-only `history_path`. Must be a non-empty string (or nil). A non-string
  # value otherwise crashes in `Path.expand`/history I/O (Exploratory #19, #27).
  defp history_path(config) do
    case Keyword.get(config, :history_path) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, "config :history_path must be a non-empty string; got #{inspect(value)}"}
        else
          {:ok, value}
        end

      other ->
        {:error, "config :history_path must be a non-empty string; got #{inspect(other)}"}
    end
  end

  # `exclude` is config-only (no CLI flag): a single Regex, a list of Regex, or
  # nil/[]. Compiled to one combined Regex (or nil) for file filtering. Comes
  # from the merged `.mutalisk.exs` + application config map (file < app).
  defp exclude(config) do
    case Keyword.get(config, :exclude) do
      nil -> {:ok, nil}
      [] -> {:ok, nil}
      %Regex{} = regex -> {:ok, [regex]}
      regexes when is_list(regexes) -> validate_exclude_list(regexes)
      other -> {:error, "config :exclude must be a Regex or list of Regex; got #{inspect(other)}"}
    end
  end

  # R17: keep each pattern as its own Regex rather than joining their `source`s
  # into one — `Regex.source/1` drops the flags, so `~r/foo/i` would silently
  # become case-sensitive and an intended-excluded file would still be mutated.
  # The matcher tests "any pattern matches", which preserves every flag.
  defp validate_exclude_list(regexes) do
    if Enum.all?(regexes, &match?(%Regex{}, &1)) do
      {:ok, regexes}
    else
      {:error, "config :exclude list must contain only Regex values"}
    end
  end

  # Test timeout bounds:
  # - 1_000 ms lower bound: ExUnit setup_all hooks alone can take
  #   100s of ms; below 1s leaves no room for actual test execution.
  # - 600_000 ms (10 min) upper bound: anything more is pathological;
  #   the user should rethink the test, not the timeout.
  @test_timeout_min_ms 1_000
  @test_timeout_max_ms 600_000
  @test_timeout_default_ms 10_000

  defp test_timeout_ms(parsed, config) do
    value =
      Keyword.get(
        parsed,
        :test_timeout_ms,
        Keyword.get(config, :test_timeout_ms, @test_timeout_default_ms)
      )

    case value do
      n when is_integer(n) and n >= @test_timeout_min_ms and n <= @test_timeout_max_ms ->
        {:ok, n}

      _other ->
        {:error,
         "--test-timeout-ms must be an integer between #{@test_timeout_min_ms} and #{@test_timeout_max_ms}; run `mix help mut`"}
    end
  end

  # Whole-suite (host) budget for ONE mutant's selected tests. Unset (nil) means
  # "derive it from the measured baseline" — see `Mut.Deadline`. The upper bound
  # is an hour: a single mutant that needs longer makes mutation testing
  # impractical long before the timeout matters.
  @suite_timeout_min_ms 1_000
  @suite_timeout_max_ms 3_600_000

  defp suite_timeout_ms(parsed, config) do
    value =
      Keyword.get(
        parsed,
        :suite_timeout_ms,
        Keyword.get(config, :suite_timeout_ms)
      )

    case value do
      nil ->
        {:ok, nil}

      n when is_integer(n) and n >= @suite_timeout_min_ms and n <= @suite_timeout_max_ms ->
        {:ok, n}

      _other ->
        {:error,
         "--suite-timeout-ms must be an integer between #{@suite_timeout_min_ms} and #{@suite_timeout_max_ms}; run `mix help mut`"}
    end
  end

  defp files(parsed, config) do
    # Default `nil` (not `["lib"]`) so file discovery falls to the orchestrator's
    # umbrella-aware `discover_files`: single-app globs `lib/`, umbrella globs
    # every `apps/<app>/lib/`. An explicit `--files`/config value is honoured
    # verbatim. (M71: a `["lib"]` default produced 0 mutants on umbrellas, whose
    # root has no lib/.)
    # `--files` may be repeated or comma-separated to mutate several glob
    # patterns in one run (M122/R130). Falls back to config, then nil.
    case Keyword.get_values(parsed, :files) do
      # CLI `--files` values are strings (OptionParser :string) but may be blank
      # (`--files ""` would expand to the whole project — #54; `--files " "` to a
      # no-op — #53). Config values may be a typo (`files: 123`/`[123]` — #18/#24)
      # or empty (`files: []` — #55). `path_list/2` rejects all of these.
      [] -> path_list("config :files", Keyword.get(config, :files))
      values -> cli_path_list("--files", values)
    end
  end

  defp split_cli_paths(values) do
    values
    |> Enum.flat_map(fn value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
    end)
  end

  # `--files`/`--test-paths` accept comma-separated patterns. An extra/trailing
  # comma (`"a.ex,,b.ex"`) previously fell through to `path_list/2`'s generic
  # "contains a blank path" message, which doesn't hint at the actual typo.
  # Reuse `string_name_list/2`'s wording — names the option and says to remove
  # the extra comma — for that specific case (T51); a genuinely blank
  # single-segment value (`--files ""`) still falls through to the generic
  # blank-path message below.
  defp cli_path_list(label, raw_values) do
    case Enum.find(raw_values, &comma_blank_segment?/1) do
      nil ->
        path_list(label, split_cli_paths(raw_values))

      value ->
        {:error, "#{label} has an empty segment in #{inspect(value)}; remove the extra comma"}
    end
  end

  defp comma_blank_segment?(value) do
    segments = String.split(value, ",")
    non_empty = Enum.reject(segments, &(String.trim(&1) == ""))
    length(segments) > 1 and length(non_empty) != length(segments)
  end

  defp mutators(parsed, config) do
    explicit = Keyword.get(parsed, :mutators, Keyword.get(config, :mutators))

    cond do
      not is_nil(explicit) ->
        with {:ok, names} <- maybe_name_list(explicit),
             :ok <- non_empty(names, "mutators"),
             :ok <- validate_mutators(names) do
          {:ok, names}
        end

      # Explicit --enable (or config) selects the target-selectable set with
      # v1.15 gating; nil resolves to Defaults.list/0.
      enable_given?(parsed, config) ->
        {:ok, nil}

      # Pure default: the default-on tier (v1 dispatch+guard + AtomLiteral).
      true ->
        {:ok, @default_on_mutators}
    end
  end

  defp enabled_targets(parsed, config) do
    value =
      Keyword.get(
        parsed,
        :enable,
        Keyword.get(config, :enabled_targets, @default_enabled_targets)
      )

    with {:ok, names} <- string_name_list("enabled_targets", value),
         :ok <- non_empty(names, "--enable targets"),
         :ok <- validate_target_names(names) do
      names_to_target_atoms(names)
    end
  end

  defp enable_given?(parsed, config) do
    Keyword.has_key?(parsed, :enable) or Keyword.has_key?(config, :enabled_targets)
  end

  defp fail_at(parsed, config) do
    value = Keyword.get(parsed, :fail_at, Keyword.get(config, :fail_at, 80.0))

    case number(value) do
      score when is_number(score) and score >= 0 and score <= 100 -> {:ok, score * 1.0}
      _invalid -> {:error, "--fail-at must be between 0 and 100; run `mix help mut`"}
    end
  end

  defp reporters(parsed, config) do
    value = Keyword.get(parsed, :reporters, Keyword.get(config, :reporters, @default_reporters))

    with {:ok, names} <- string_name_list("reporters", value),
         :ok <- non_empty(names, "reporters"),
         :ok <- validate_reporter_names(names) do
      with {:ok, reporters} <- names_to_reporter_atoms(names) do
        {:ok, Enum.uniq(reporters)}
      end
    end
  end

  defp output_path(parsed, config) do
    case Keyword.get(
           parsed,
           :output_path,
           Keyword.get(config, :output_path, "stryker.report.json")
         ) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, "output_path must be a non-empty string; got #{inspect(value)}"}
        else
          {:ok, value}
        end

      other ->
        {:error, "output_path must be a non-empty string; got #{inspect(other)}"}
    end
  end

  defp concurrency(parsed, config) do
    # v1.6 default: parallel workers, capped at 4 by the M17 milestone.
    # Cap exists because the speedup curve flattens past 4 on the M17
    # reference machine (Decimal: 3.06x at c=4 vs ~3.5x at c=8); each
    # worker BEAM costs ~50-100MB baseline so 4 keeps memory pressure
    # bounded across hardware. Users with more cores can raise it
    # explicitly via `--concurrency 8` or higher.
    default = min(System.schedulers_online(), 4)
    max = max(System.schedulers_online() * 4, @min_explicit_concurrency_ceiling)
    value = Keyword.get(parsed, :concurrency, Keyword.get(config, :concurrency, default))

    case value do
      value when is_integer(value) and value >= 1 and value <= max ->
        {:ok, value}

      value when is_integer(value) and value > max ->
        {:error, "--concurrency must be between 1 and #{max} on this machine; run `mix help mut`"}

      _invalid ->
        {:error, "--concurrency must be at least 1; run `mix help mut`"}
    end
  end

  defp max_mutants(parsed, config) do
    case Keyword.get(parsed, :max_mutants, Keyword.get(config, :max_mutants)) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _invalid -> {:error, "max_mutants must be at least 1; run `mix help mut`"}
    end
  end

  # Config-only per-file coverage-collection timeout (ms). `nil` lets
  # `Mut.Coverage.Runner` use its built-in default. Surfaced so a project with a
  # slow test file under `:cover` instrumentation can raise the bound instead of
  # silently degrading that file to static selection (T9).
  defp coverage_timeout_ms(config) do
    case Keyword.get(config, :coverage_timeout_ms) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _invalid -> {:error, "coverage_timeout_ms must be a positive integer"}
    end
  end

  defp selection(parsed, config) do
    # M65: default flipped static -> coverage_with_static_fallback (v1.5's
    # planned default), now that M64 makes coverage crash-safe (per-file
    # degrade). `--selection static` remains the fully-portable escape hatch.
    value =
      Keyword.get(
        parsed,
        :selection,
        Keyword.get(config, :selection, :coverage_with_static_fallback)
      )

    # Validate string FIRST, then convert to atom to avoid interning untrusted input.
    # For atoms (from config defaults), convert to string; for strings (from CLI), normalize.
    # A non-string/atom config value (e.g. `selection: 123`) must not crash
    # `normalize_name/1` — reject it with a friendly error.
    if is_binary(value) or is_atom(value) do
      name = normalize_name(value)
      known_strings = Enum.map(@known_selection_modes, &Atom.to_string/1)

      if name in known_strings do
        # Safe: every @known_selection_modes atom exists at compile time.
        {:ok, String.to_existing_atom(name)}
      else
        # Render the rejected value in atom form (`:name`) without interning it.
        {:error, "unknown --selection mode :#{name}; known: #{known(@known_selection_modes)}"}
      end
    else
      {:error,
       "selection must be one of #{known(@known_selection_modes)}; got #{inspect(value, charlists: :as_lists)}"}
    end
  end

  # Default `nil` (not `["test"]`) so the orchestrator's umbrella-aware path
  # resolution applies: a single app uses `test/`; an umbrella has no root
  # `test/`, so each child app's `apps/<app>/test/` is used instead. An explicit
  # config/CLI value is honoured verbatim. A hardcoded `["test"]` default found
  # zero test files in umbrellas, so every mutant fell to the "all tests" bucket
  # with a recorded selected-test count of 0 (Exploratory issue #3).
  # `--test-paths` mirrors `--files`: repeatable or comma-separated, CLI wins
  # over config (T10 rule), and both spellings reject absolute paths so a
  # project-relative test tree isn't silently confused with a host path.
  defp test_paths(parsed, config) do
    case Keyword.get_values(parsed, :test_paths) do
      [] -> path_list("config :test_paths", Keyword.get(config, :test_paths))
      values -> cli_path_list("--test-paths", values)
    end
  end

  # Only called for a non-nil `explicit` value (the `not is_nil(explicit)`
  # branch in `mutators/2`). Reuses `string_name_list/2` so mutators get the same
  # treatment as reporters/targets: non-string/atom entries are rejected with a
  # friendly error rather than a raw FunctionClauseError (#24/#25 sibling), and a
  # trailing-comma empty segment (`arithmetic,`) is rejected (#66).
  defp maybe_name_list(value), do: string_name_list("mutators", value)

  # Validator for path-valued keys (`files`, `test_paths`): `nil` (use the
  # umbrella-aware default), a non-blank string, or a NON-EMPTY list of non-blank
  # strings. Rejects, with a friendly error rather than a crash or silent no-op:
  #   - non-string entries / wrong types (#18, #24, #25)
  #   - empty list `[]` (#55, #56)
  #   - empty string `""` (would expand to the whole project — #54)
  #   - whitespace-only entries (no-op run — #53)
  defp path_list(_label, nil), do: {:ok, nil}
  defp path_list(label, value) when is_binary(value), do: path_list(label, [value])

  defp path_list(label, value) when is_list(value) do
    cond do
      value == [] ->
        {:error, "#{label} must not be empty; run `mix help mut`"}

      not Enum.all?(value, &is_binary/1) ->
        {:error,
         "#{label} must be a string or list of strings; got #{inspect(value, charlists: :as_lists)}"}

      Enum.any?(value, &(String.trim(&1) == "")) ->
        {:error, "#{label} contains a blank path; run `mix help mut`"}

      label in ["config :test_paths", "--test-paths"] and
          Enum.any?(value, &(Path.type(&1) == :absolute)) ->
        {:error, "#{label} must contain project-relative paths; got absolute path"}

      true ->
        {:ok, value}
    end
  end

  defp path_list(label, other),
    do:
      {:error,
       "#{label} must be a string or list of strings; got #{inspect(other, charlists: :as_lists)}"}

  # Reject an explicitly-empty selection (`--reporters ""`, `mutators: []`, …).
  # Defaults are non-empty, so an empty list here always means the user asked for
  # nothing, which would silently no-op the run (Exploratory #11–13, #21–23).
  defp non_empty([], label), do: {:error, "#{label} must not be empty; run `mix help mut`"}
  defp non_empty(_names, _label), do: :ok

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  # Only called with a non-nil list (from `maybe_name_list/1` in the
  # `not is_nil(explicit)` branch), so there is no nil clause.
  defp validate_mutators(names) do
    # Reports display each mutator by its CamelCase module name (`Arithmetic`).
    # Accept that form here too — `resolve_mutators/1` applies the same
    # `Macro.underscore` fallback — so a name copied from a report validates.
    unknown =
      Enum.reject(names, &(&1 in @known_mutators or Macro.underscore(&1) in @known_mutators))

    if unknown == [] do
      :ok
    else
      {:error, unknown_mutator_message(List.first(unknown))}
    end
  end

  # Flags that may legitimately appear more than once (collected into a list).
  @repeatable_flags ["files", "test_paths"]

  defp duplicate_cli_option?(argv) do
    argv
    |> Enum.filter(&String.starts_with?(&1, "--"))
    |> Enum.map(&(&1 |> String.trim_leading("--") |> String.split("=", parts: 2) |> List.first()))
    |> Enum.map(&String.trim_leading(&1, "no-"))
    # Normalise `-`/`_` so the dash-spelled `--test-paths` matches the
    # underscore-spelled `@repeatable_flags` entry (T46). (An underscore-spelled
    # flag like `--fail_at` is rejected by OptionParser as invalid before this
    # check runs, so it cannot itself create a duplicate.)
    |> Enum.map(&String.replace(&1, "-", "_"))
    |> Enum.reject(&(&1 in @repeatable_flags))
    |> Enum.frequencies()
    |> Enum.any?(fn {_key, count} -> count > 1 end)
  end

  defp validate_config_keys(config) do
    unknown = config |> Keyword.keys() |> Enum.reject(&(&1 in @known_config_keys))

    case unknown do
      [] ->
        :ok

      [key | _] ->
        {:error,
         "unknown config key #{inspect(key)}; known: #{Enum.map_join(@known_config_keys, ", ", &inspect/1)}"}
    end
  end

  # Convert string name to target atom ONLY after validation of the string.
  # Avoid interning arbitrary atoms from untrusted input.
  defp name_to_target_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> {:error, name}
  end

  # Convert string name to reporter atom ONLY after validation of the string.
  defp name_to_reporter_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> {:error, name}
  end

  # Batch-convert validated target names to atoms.
  defp names_to_target_atoms(names) do
    atoms = Enum.map(names, &name_to_target_atom/1)

    if Enum.any?(atoms, &match?({:error, _}, &1)) do
      {:error, "internal error: validated target name failed to convert to atom"}
    else
      {:ok, atoms}
    end
  end

  # Batch-convert validated reporter names to atoms.
  defp names_to_reporter_atoms(names) do
    atoms = Enum.map(names, &name_to_reporter_atom/1)

    if Enum.any?(atoms, &match?({:error, _}, &1)) do
      {:error, "internal error: validated reporter name failed to convert to atom"}
    else
      {:ok, atoms}
    end
  end

  # Coerce input (atom, string, or list) to a normalized list of strings.
  # `label` is the config key name, used in friendly errors.
  defp string_name_list(_label, value) when is_atom(value) do
    {:ok, [Atom.to_string(value) |> normalize_name()]}
  end

  defp string_name_list(label, value) when is_binary(value) do
    segments = value |> String.split(",") |> Enum.map(&String.trim/1)
    non_empty = Enum.reject(segments, &(&1 == ""))

    cond do
      # Whole value blank ("" / "  " / ","): yield [] so `non_empty/2` reports
      # "must not be empty" with the right wording.
      non_empty == [] ->
        {:ok, []}

      # A trailing/extra comma left an empty segment ("terminal,"): reject it
      # rather than silently dropping it, so a typo is not hidden (#65, #66, #67).
      length(non_empty) != length(segments) ->
        {:error, "#{label} has an empty segment in #{inspect(value)}; remove the extra comma"}

      true ->
        {:ok, Enum.map(non_empty, &normalize_name/1)}
    end
  end

  defp string_name_list(label, value) when is_list(value) do
    # Config lists may carry non-string/atom entries (`reporters: [123]`); reject
    # with a config-typed message instead of stringifying to a CLI-style unknown
    # value error (#69, #70).
    if Enum.all?(value, &(is_binary(&1) or is_atom(&1))) do
      {:ok, Enum.map(value, &normalize_name(to_string(&1)))}
    else
      {:error,
       "config :#{label} must contain only strings or atoms; got #{inspect(value, charlists: :as_lists)}"}
    end
  end

  defp string_name_list(label, _value) do
    {:error, "config :#{label} must be a string, atom, or list of strings/atoms"}
  end

  # Validate normalized target names against known list (string validation).
  defp validate_target_names(names) do
    known_strings = Enum.map(@known_targets, &Atom.to_string/1)
    unknown = Enum.reject(names, &(&1 in known_strings))

    if unknown == [] do
      :ok
    else
      # Render the rejected value in atom form (`:name`) without interning it.
      {:error, "unknown --enable target :#{List.first(unknown)}; known: #{known(@known_targets)}"}
    end
  end

  # Validate normalized reporter names against known list (string validation).
  defp validate_reporter_names(names) do
    known_strings = Enum.map(@known_reporters, &Atom.to_string/1)
    unknown = Enum.reject(names, &(&1 in known_strings))

    if unknown == [] do
      :ok
    else
      # Show the known list in the documented CLI spelling (hyphenated:
      # `stryker-json`, `github-actions`) rather than the internal underscore
      # atoms, so the error matches `mix help mut` (#68). The rejected value is
      # rendered in atom form (`:name`) without interning it.
      known = Enum.map_join(@known_reporters, ", ", &String.replace(Atom.to_string(&1), "_", "-"))
      {:error, "unknown --reporters value :#{List.first(unknown)}; known: #{known}"}
    end
  end

  defp normalize_name(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_name()

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
      ],
      "integer_literal" => Mut.Mutator.IntegerLiteral,
      "boolean_literal" => Mut.Mutator.BooleanLiteral,
      "string_literal" => Mut.Mutator.StringLiteral,
      "float_literal" => Mut.Mutator.FloatLiteral,
      "nil_literal" => Mut.Mutator.NilLiteral,
      "atom_literal" => Mut.Mutator.AtomLiteral,
      "collection_empty" => Mut.Mutator.CollectionEmpty,
      "concat_operator" => Mut.Mutator.ConcatOperator,
      "bitwise_operator" => Mut.Mutator.BitwiseOperator,
      "membership" => Mut.Mutator.Membership,
      "pin" => Mut.Mutator.Pin,
      "function_replace" => Mut.Mutator.FunctionReplace,
      "negate_conditional" => Mut.Mutator.NegateConditional,
      "statement_delete" => Mut.Mutator.StatementDelete,
      "clause_delete" => Mut.Mutator.ClauseDelete,
      "guard_boolean" => Mut.Mutator.GuardBoolean,
      "pipeline_drop_stage" => Mut.Mutator.PipelineDropStage,
      "map_update_drop" => Mut.Mutator.MapUpdateDrop,
      "receive_timeout" => Mut.Mutator.ReceiveTimeout,
      "variable_replace" => Mut.Mutator.VariableReplace,
      "variable_to_literal" => Mut.Mutator.VariableToLiteral,
      "body_literal" => [Mut.Mutator.IntegerLiteral, Mut.Mutator.BooleanLiteral]
    }
  end

  defp unknown_mutator_message(name) do
    "unknown mutator #{inspect(name)}; known: #{Enum.join(@known_mutators, ", ")}; run `mix help mut`"
  end

  defp known(values), do: Enum.map_join(values, ", ", &Atom.to_string/1)
end
