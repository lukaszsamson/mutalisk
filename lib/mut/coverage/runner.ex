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
    started = monotonic_ms()
    test_paths = Keyword.get(opts, :test_paths, ["test"])
    timeout_ms = Keyword.get(opts, :timeout_per_file_ms, @default_timeout_ms)
    fallback_static_tests = Keyword.get(opts, :fallback_static_tests, %{})
    mutalisk_path = Keyword.get(opts, :mutalisk_path, File.cwd!())

    with :ok <- ensure_overlay(work_copy_root),
         :ok <- deps_compile(work_copy_root, mutalisk_path),
         :ok <- compile(work_copy_root, mutalisk_path) do
      test_files = discover_test_files(work_copy_root, test_paths)

      test_files
      |> collect_files(work_copy_root, timeout_ms, mutalisk_path)
      |> put_collection_metadata(started, fallback_static_tests)
    end
  end

  defp collect_files(test_files, root, timeout_ms, mutalisk_path) do
    Enum.reduce_while(test_files, {:ok, empty_oracle()}, fn test_file, {:ok, oracle} ->
      case run_test_file(root, test_file, timeout_ms, mutalisk_path) do
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

  defp run_mix(root, args, mutalisk_path) do
    case System.cmd("mix", args, cd: root, env: child_env(mutalisk_path), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:mix_failed, args, exit_code, output_tail(output)}}
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
      port =
        Port.open({:spawn_executable, mix_path}, [
          {:args,
           ["run", "--no-compile", "--no-deps-check", "--no-archives-check", "-e", script]},
          {:cd, root},
          {:env, port_env(mutalisk_path)},
          :stderr_to_stdout,
          :exit_status,
          :binary
        ])

      collect_port(port, "", timeout_ms)
    end
  end

  defp parse_test_output(root, test_file, out_path, output) do
    {line, function} = read_coverage_term(out_path)
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

  defp read_coverage_term(out_path) do
    case out_path |> File.read!() |> :erlang.binary_to_term() do
      {line, function} -> {line, function}
      {line, function, _result} -> {line, function}
    end
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
    Code.prepend_paths(Path.wildcard("#{Path.join(root, @build_path)}/lib/*/ebin"))
    for ebin <- Path.wildcard("#{Path.join(root, @build_path)}/lib/*/ebin"),
        Path.basename(Path.dirname(ebin)) not in ["mutalisk", "jason"] do
      for beam <- Path.wildcard(Path.join(ebin, "*.beam")) do
        {:ok, _module} = :cover.compile_beam(String.to_charlist(beam))
      end
    end
    ExUnit.configure(formatters: [Mut.Worker.Formatter], autorun: false, max_cases: 1)
    Code.require_file("test/test_helper.exs", "#{root}")
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

  defp port_env(mutalisk_path) do
    Enum.map(child_env(mutalisk_path), fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp mix_path do
    case System.find_executable("mix") do
      nil -> {:error, :mix_not_found}
      path -> {:ok, path}
    end
  end

  defp collect_port(port, output, timeout_ms) do
    receive do
      {^port, {:data, data}} -> collect_port(port, output <> data, timeout_ms)
      {^port, {:exit_status, code}} -> {:exit, code, output}
    after
      timeout_ms ->
        kill_port(port)
        {:timeout, output}
    end
  end

  defp kill_port(port) do
    os_pid = Port.info(port, :os_pid)
    Port.close(port)

    case os_pid do
      {:os_pid, pid} when is_integer(pid) ->
        kill_process_tree(pid)

      _unknown ->
        :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp kill_process_tree(pid) do
    descendants = descendant_pids(pid)

    Enum.each(descendants, fn child_pid ->
      System.cmd("kill", ["-TERM", Integer.to_string(child_pid)], stderr_to_stdout: true)
    end)

    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    Process.sleep(100)

    Enum.each(descendants, fn child_pid ->
      System.cmd("kill", ["-KILL", Integer.to_string(child_pid)], stderr_to_stdout: true)
    end)

    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp descendant_pids(pid) do
    pid
    |> child_pids()
    |> Enum.flat_map(fn child_pid -> [child_pid | descendant_pids(child_pid)] end)
  end

  defp child_pids(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_pid/1)

      _no_children ->
        []
    end
  end

  defp parse_pid(value) do
    case Integer.parse(value) do
      {child_pid, ""} -> [child_pid]
      _invalid -> []
    end
  end

  defp output_tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp monotonic_ms, do: :erlang.monotonic_time(:millisecond)
end
