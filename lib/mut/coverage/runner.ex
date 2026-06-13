defmodule Mut.Coverage.Runner do
  @moduledoc "Collects v1.5 per-test-file line/function coverage in an isolated build path."

  alias Mut.Coverage.Parser
  alias Mut.CoverageOracle
  alias Mut.TestRuntime

  @build_path "_build/mut_coverage"
  @deps_path "_build/mut_coverage/deps"
  @default_timeout_ms 60_000

  @spec run(Path.t(), keyword) :: {:ok, CoverageOracle.t()} | {:error, term}
  def run(work_copy_root, opts \\ []) do
    test_paths = Keyword.get(opts, :test_paths, ["test"])
    timeout_ms = Keyword.get(opts, :timeout_per_file_ms, @default_timeout_ms)
    fallback_static_tests = Keyword.get(opts, :fallback_static_tests, %{})
    mutalisk_path = Keyword.get(opts, :mutalisk_path, File.cwd!())

    with :ok <- ensure_overlay(work_copy_root),
         :ok <- deps_compile(work_copy_root, mutalisk_path),
         :ok <- compile(work_copy_root, mutalisk_path) do
      test_files = discover_test_files(work_copy_root, test_paths)

      # R7: start timing AFTER the one-time cold `_build/mut_coverage` compile.
      # The pathological-coverage heuristic compares this wall against the
      # baseline test wall, which is compile-free (the oracle build is already
      # warm) — counting the cold compile here made coverage look pathological
      # on small/fast projects and silently self-disable.
      started = monotonic_ms()

      test_files
      |> collect_files(work_copy_root, timeout_ms, mutalisk_path)
      |> put_collection_metadata(started, fallback_static_tests)
    end
  end

  # M64: per-file crash-tolerant collection. A test file whose coverage
  # collection fails (exception / timeout / BEAM crash) is RECORDED as degraded
  # and the run CONTINUES, instead of aborting the whole run (the v1.18 M61
  # failure: gettext/credo/timex). Degraded files fall back to static selection
  # (Mut.TestSelection.Coverage unions their static coverage), so the mutants
  # they cover still run their tests — no false survivors.
  defp collect_files(test_files, root, timeout_ms, mutalisk_path) do
    {oracle, degraded} =
      Enum.reduce(test_files, {empty_oracle(), []}, fn test_file, {oracle, degraded} ->
        case run_test_file(root, test_file, timeout_ms, mutalisk_path) do
          {:ok, partial} ->
            {merge_oracle(oracle, partial), degraded}

          {:error, reason} ->
            {oracle, [{Path.relative_to(test_file, root), reason} | degraded]}
        end
      end)

    {:ok, %{oracle | degraded_test_files: Enum.reverse(degraded)}}
  end

  defp put_collection_metadata({:ok, oracle}, started, fallback_static_tests) do
    {:ok,
     %{
       oracle
       | collection_wall_ms: monotonic_ms() - started,
         fallback_static_tests: fallback_static_tests
     }}
  end

  defp ensure_overlay(root) do
    if File.exists?(Path.join(root, "mix_user.exs")) do
      :ok
    else
      Mut.WorkCopy.install_overlay(root, :coverage)
    end
  end

  defp discover_test_files(root, test_paths) do
    test_paths
    |> Enum.flat_map(fn test_path ->
      path = if Path.type(test_path) == :absolute, do: test_path, else: Path.join(root, test_path)

      cond do
        File.regular?(test_path) and String.ends_with?(test_path, "_test.exs") ->
          [test_path]

        File.regular?(path) and String.ends_with?(path, "_test.exs") ->
          [path]

        true ->
          path
          |> Path.join("**/*_test.exs")
          |> Path.wildcard()
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp deps_compile(root, mutalisk_path) do
    run_mix(
      root,
      ["do", "deps.get", "+", "deps.compile", "--include-children", "mutalisk"],
      mutalisk_path
    )
  end

  defp compile(root, mutalisk_path), do: run_mix(root, ["compile"], mutalisk_path)

  # Generous ceiling for the one-time coverage setup compiles (deps.get +
  # deps.compile, then compile). Finite so a wedged toolchain can't hang the run
  # forever — consistent with the finite timeouts on every other compile-phase
  # child (R5).
  @setup_timeout_ms 600_000

  defp run_mix(root, args, mutalisk_path) do
    case Mut.ChildProcess.run("mix", args,
           cd: root,
           env: child_env(mutalisk_path),
           timeout_ms: @setup_timeout_ms
         ) do
      {:exit, 0, _output} -> :ok
      {:exit, exit_code, output} -> {:error, {:mix_failed, args, exit_code, output_tail(output)}}
      {:timeout, output} -> {:error, {:mix_timeout, args, @setup_timeout_ms, output_tail(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_test_file(root, test_file, timeout_ms, mutalisk_path) do
    out_path =
      Path.join([root, "tmp", "mut_coverage", "#{:erlang.unique_integer([:positive])}.term"])

    File.mkdir_p!(Path.dirname(out_path))
    script = coverage_script(root, test_file, out_path)

    case run_coverage_mix(root, script, timeout_ms, mutalisk_path) do
      {:error, reason} ->
        {:error, reason}

      {:timeout, _output} ->
        {:error, {:coverage_test_timeout, Path.relative_to(test_file, root), timeout_ms}}

      {:exit, exit_code, output} when exit_code != 0 ->
        {:error,
         {:coverage_test_failed, Path.relative_to(test_file, root), exit_code,
          output_tail(output)}}

      {:exit, 0, output} ->
        if File.exists?(out_path) do
          parse_test_output(root, test_file, out_path, output)
        else
          {:error,
           {:coverage_output_missing, Path.relative_to(test_file, root), output_tail(output)}}
        end
    end
  end

  defp run_coverage_mix(root, script, timeout_ms, mutalisk_path) do
    with {:ok, mix_path} <- mix_path() do
      Mut.ChildProcess.run(
        mix_path,
        ["run", "--no-compile", "--no-deps-check", "--no-archives-check", "-e", script],
        cd: root,
        env: child_env(mutalisk_path),
        timeout_ms: timeout_ms,
        max_output_bytes: 512_000
      )
    end
  end

  defp parse_test_output(root, test_file, out_path, output) do
    {line, function} = read_coverage_term(out_path)
    # T7: do NOT prepend the target's ebins to the HOST code path. `Parser`
    # resolves module sources by reading each `.beam`'s compile_info directly
    # (`beam_module_source/2`, no load) — loading the target's modules into the
    # mutalisk host VM polluted it and risked version conflicts with mutalisk's
    # own deps. The coverage CHILD already loads what `:cover` needs.
    test_id = {:file, Path.relative_to(test_file, root)}
    {by_line, by_function} = Parser.parse(line, function, test_id, root)

    test_runtime_ms =
      output
      |> TestRuntime.from_formatter_output()
      |> Map.new(fn {_key, value} -> {test_id, value} end)

    {:ok,
     %CoverageOracle{
       by_line: by_line,
       by_function: by_function,
       test_runtime_ms: test_runtime_ms
     }}
  end

  defp read_coverage_term(out_path) do
    case out_path |> File.read!() |> :erlang.binary_to_term() do
      {line, function} -> {line, function}
      {line, function, _result} -> {line, function}
    end
  end

  # R7: resolve the test_helper relative to the test FILE, not the project root.
  # An umbrella root has no `test/test_helper.exs` — each child app carries its
  # own `apps/<app>/test/test_helper.exs`. Hardcoding the root path degraded
  # every per-file coverage run on umbrellas, silently collapsing coverage
  # selection to whole-suite static. Walk up from the test file to the nearest
  # `test_helper.exs`; fall back to the root helper for the single-app shape.
  defp resolve_test_helper(test_file, root) do
    test_file
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while("test/test_helper.exs", fn dir, fallback ->
      candidate = Path.join(dir, "test_helper.exs")

      cond do
        File.exists?(candidate) -> {:halt, Path.relative_to(candidate, root)}
        dir in [root, "/", "."] -> {:halt, fallback}
        true -> {:cont, fallback}
      end
    end)
  end

  defp coverage_script(root, test_file, out_path) do
    test_helper = resolve_test_helper(test_file, root)

    """
    tools = Path.wildcard(Path.join([List.to_string(:code.root_dir()), "lib", "tools-*", "ebin"])) |> List.first()
    :code.add_path(String.to_charlist(tools))
    Application.ensure_all_started(:tools)
    :cover.start()
    Code.prepend_paths(Path.wildcard("#{Path.join(root, @build_path)}/lib/*/ebin"))
    for ebin <- Path.wildcard("#{Path.join(root, @build_path)}/lib/*/ebin"),
        Path.basename(Path.dirname(ebin)) != "mutalisk" do
      for beam <- Path.wildcard(Path.join(ebin, "*.beam")) do
        {:ok, _module} = :cover.compile_beam(String.to_charlist(beam))
      end
    end
    ExUnit.configure(formatters: [Mut.Worker.Formatter], autorun: false, max_cases: 1)
    Code.require_file("#{test_helper}", "#{root}")
    # Test modules may still declare `async: true`; max_cases: 1 serializes this
    # per-file run, while v1.5 intentionally attributes only at file granularity.
    ExUnit.configure(formatters: [Mut.Worker.Formatter], autorun: false, max_cases: 1)
    Code.require_file("#{Path.relative_to(test_file, root)}", "#{root}")
    result = ExUnit.run()
    line = :cover.analyse(:coverage, :line)
    function = :cover.analyse(:coverage, :function)
    File.write!("#{out_path}", :erlang.term_to_binary({line, function, result}))
    if result.failures > 0 do
      System.halt(2)
    else
      System.halt(0)
    end
    """
  end

  defp merge_oracle(left, right) do
    %CoverageOracle{
      by_line: merge_set_maps(left.by_line, right.by_line),
      by_function: merge_set_maps(left.by_function, right.by_function),
      test_runtime_ms: Map.merge(left.test_runtime_ms, right.test_runtime_ms),
      fallback_static_tests: Map.merge(left.fallback_static_tests, right.fallback_static_tests),
      collection_wall_ms: left.collection_wall_ms + right.collection_wall_ms
    }
  end

  defp merge_set_maps(left, right) do
    Map.merge(left, right, fn _key, a, b -> MapSet.union(a, b) end)
  end

  defp empty_oracle, do: %CoverageOracle{}

  defp child_env(mutalisk_path) do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", @build_path},
      {"MIX_DEPS_PATH", @deps_path},
      {"MUTALISK_ROLE", "coverage"},
      {"MUTALISK_PATH", mutalisk_path}
    ]
  end

  defp mix_path do
    case System.find_executable("mix") do
      nil -> {:error, :mix_not_found}
      path -> {:ok, path}
    end
  end

  defp output_tail(output), do: Mut.ChildProcess.output_tail(output)

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
end
