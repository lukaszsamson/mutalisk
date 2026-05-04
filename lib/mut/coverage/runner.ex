defmodule Mut.Coverage.Runner do
  @moduledoc "Collects v1.5 per-test-file line/function coverage in an isolated build path."

  alias Mut.Coverage.Parser
  alias Mut.CoverageOracle
  alias Mut.TestRuntime

  @build_path "_build/mut_coverage"
  @deps_path "_build/mut_coverage/deps"

  @spec run(Path.t(), keyword) :: {:ok, CoverageOracle.t()} | {:error, term}
  def run(work_copy_root, opts \\ []) do
    started = monotonic_ms()
    test_paths = Keyword.get(opts, :test_paths, ["test"])
    timeout_ms = Keyword.get(opts, :timeout_per_file_ms, 60_000)
    fallback_static_tests = Keyword.get(opts, :fallback_static_tests, %{})

    with :ok <- ensure_overlay(work_copy_root),
         :ok <- deps_compile(work_copy_root),
         :ok <- compile(work_copy_root) do
      test_files = discover_test_files(work_copy_root, test_paths)

      test_files
      |> collect_files(work_copy_root, timeout_ms)
      |> put_collection_metadata(started, fallback_static_tests)
    end
  end

  defp collect_files(test_files, root, timeout_ms) do
    Enum.reduce_while(test_files, {:ok, empty_oracle()}, fn test_file, {:ok, oracle} ->
      case run_test_file(root, test_file, timeout_ms) do
        {:ok, partial} -> {:cont, {:ok, merge_oracle(oracle, partial)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_collection_metadata({:error, _reason} = error, _started, _fallback_static_tests),
    do: error

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
      root
      |> Path.join(test_path)
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp deps_compile(root) do
    run_mix(root, ["do", "deps.get", "+", "deps.compile", "--include-children", "mutalisk"])
  end

  defp compile(root), do: run_mix(root, ["compile"])

  defp run_mix(root, args) do
    case System.cmd("mix", args, cd: root, env: child_env(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:mix_failed, args, exit_code, output_tail(output)}}
    end
  end

  defp run_test_file(root, test_file, timeout_ms) do
    out_path =
      Path.join([root, "tmp", "mut_coverage", "#{:erlang.unique_integer([:positive])}.term"])

    File.mkdir_p!(Path.dirname(out_path))
    script = coverage_script(root, test_file, out_path)

    task =
      Task.async(fn ->
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", script],
          cd: root,
          env: child_env(),
          stderr_to_stdout: true
        )
      end)

    result = Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill)

    case result do
      nil ->
        {:error, {:coverage_test_timeout, Path.relative_to(test_file, root), timeout_ms}}

      {:ok, {output, exit_code}} when exit_code != 0 ->
        {:error,
         {:coverage_test_failed, Path.relative_to(test_file, root), exit_code,
          output_tail(output)}}

      {:ok, {output, 0}} ->
        if File.exists?(out_path) do
          parse_test_output(root, test_file, out_path, output)
        else
          {:error,
           {:coverage_output_missing, Path.relative_to(test_file, root), output_tail(output)}}
        end
    end
  end

  defp parse_test_output(root, test_file, out_path, output) do
    {line, function} = out_path |> File.read!() |> :erlang.binary_to_term()
    prepend_project_ebins(root)
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

  defp prepend_project_ebins(root) do
    root
    |> Path.join("#{@build_path}/lib/*/ebin")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["mutalisk", "jason"]))
    |> Enum.each(&(&1 |> String.to_charlist() |> Code.prepend_path()))
  end

  defp coverage_script(root, test_file, out_path) do
    """
    tools = Path.wildcard(Path.join([List.to_string(:code.root_dir()), "lib", "tools-*", "ebin"])) |> List.first()
    :code.add_path(String.to_charlist(tools))
    Application.ensure_all_started(:tools)
    :cover.start()
    for ebin <- Path.wildcard("#{Path.join(root, @build_path)}/lib/*/ebin"),
        Path.basename(Path.dirname(ebin)) not in ["mutalisk", "jason"] do
      :cover.compile_beam_directory(String.to_charlist(ebin))
    end
    ExUnit.configure(formatters: [Mut.Worker.Formatter], autorun: false)
    Code.require_file("test/test_helper.exs", "#{root}")
    ExUnit.configure(formatters: [Mut.Worker.Formatter], autorun: false)
    Code.require_file("#{Path.relative_to(test_file, root)}", "#{root}")
    result = ExUnit.run()
    line = :cover.analyse(:coverage, :line)
    function = :cover.analyse(:coverage, :function)
    File.write!("#{out_path}", :erlang.term_to_binary({line, function}))
    if result.failures > 0, do: System.halt(2)
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

  defp child_env do
    [
      {"MIX_ENV", "test"},
      {"MIX_BUILD_PATH", @build_path},
      {"MIX_DEPS_PATH", @deps_path},
      {"MUTALISK_ROLE", "coverage"},
      {"MUTALISK_PATH", File.cwd!()}
    ]
  end

  defp output_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
end
