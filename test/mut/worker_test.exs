defmodule Mut.WorkerTest do
  use ExUnit.Case, async: false

  @moduledoc false

  alias Mut.Sandbox
  alias Mut.Worker

  test "env and args match the build-path contract" do
    assert Worker.env(12) == [
             {"MIX_ENV", "test"},
             {"MIX_BUILD_PATH", "_build/mut_schema"},
             {"MIX_DEPS_PATH", "_build/mut_schema/deps"},
             {"MUTALISK_ROLE", "worker"},
             {"MUTALISK_PATH", Path.expand(File.cwd!())},
             {"MUT_ACTIVE", "12"}
           ]

    assert Worker.args(["test/arith_test.exs"]) == [
             "test",
             "--no-compile",
             "--no-deps-check",
             "--no-archives-check",
             "--max-failures",
             "1",
             "--formatter",
             "Mut.Worker.Formatter",
             "test/arith_test.exs"
           ]

    assert Worker.args([]) |> List.last() == "Mut.Worker.Formatter"
  end

  test "run_schema classifies killed and sends expected process inputs" do
    path = fake_sandbox("killed")
    mix = mix_shim("killed", 1)

    result =
      Worker.run_schema(%Sandbox{id: 1, path: path}, 42, ["test/arith_test.exs"], mix_path: mix)

    assert result.status == :killed
    assert result.killing_test == "ArithTest score"
    assert File.read!(Path.join(path, "mut_active")) == "42"

    assert File.read!(Path.join(path, "argv")) =~
             "--no-compile --no-deps-check --no-archives-check"
  end

  test "run_schema classifies survived" do
    path = fake_sandbox("survived")
    mix = mix_shim("survived", 0)

    result = Worker.run_schema(%Sandbox{id: 1, path: path}, 7, [], mix_path: mix)

    assert result.status == :survived
  end

  test "run_schema closes timed out ports" do
    path = fake_sandbox("timeout")
    File.write!(Path.join(path, "mix.exs"), "mix")
    mix = timeout_shim()

    result = Worker.run_schema(%Sandbox{id: 1, path: path}, 7, [], mix_path: mix, timeout_ms: 50)

    assert result.status == :timeout
  end

  test "run_schema returns clear error when sandbox is missing mix.exs" do
    path = fake_sandbox("missing_mix")
    File.rm!(Path.join(path, "mix.exs"))
    mix = mix_shim("missing_mix", 0)

    result =
      Worker.run_schema(%Sandbox{id: 1, path: path}, 7, [], mix_path: mix, retry_on_error: false)

    assert result.status == :error
    assert result.raw_output =~ "sandbox_not_materialized"
    assert result.raw_output =~ "mix.exs"
  end

  test "run_schema resets sandbox before retrying infrastructure errors" do
    path = fake_sandbox("retry_reset")
    baseline_source = fake_sandbox("retry_reset_baseline")
    File.mkdir_p!(Path.join(path, "_build/mut_schema/lib/demo_app/ebin"))
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(baseline_source, "_build/mut_schema/lib/demo_app/ebin"))
    File.mkdir_p!(Path.join(baseline_source, "lib"))
    File.write!(Path.join(path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"), "beam")
    File.write!(Path.join(path, "lib/arith.ex"), "source")

    File.write!(
      Path.join(baseline_source, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"),
      "beam"
    )

    File.write!(Path.join(baseline_source, "lib/arith.ex"), "source")

    mix = retry_shim()

    sandbox = %Sandbox{
      id: 1,
      path: path,
      baseline_source: baseline_source,
      baseline_snapshot: %{
        "lib/demo_app/ebin/Elixir.Arith.beam" =>
          sha256(Path.join(path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam"))
      }
    }

    result = Worker.run_schema(sandbox, 7, [], mix_path: mix)

    assert result.status == :survived
    assert File.read!(Path.join(path, "attempts")) == "2"

    assert File.read!(Path.join(path, "_build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam")) ==
             "beam"
  end

  defp fake_sandbox(name) do
    path = Path.expand(Path.join(["tmp", "tests", "worker", name]))
    File.rm_rf!(path)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "mix.exs"), "mix")
    path
  end

  defp mix_shim(name, exit_code) do
    path = Path.expand(Path.join(["tmp", "tests", "worker", "mix_#{name}.sh"]))
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/usr/bin/env bash
    printf '%s' "$MUT_ACTIVE" > mut_active
    printf '%s' "$*" > argv
    if [ #{exit_code} -eq 0 ]; then
      printf '%s\n' '{"event":"test_finished","module":"ArithTest","test":"score","status":"passed","duration_us":1}'
      printf '%s\n' '{"event":"suite_finished","total":1,"failed":0,"passed":1,"skipped":0}'
    else
      printf '%s\n' '{"event":"test_finished","module":"ArithTest","test":"score","status":"failed","duration_us":1,"error":"boom"}'
      printf '%s\n' '{"event":"suite_finished","total":1,"failed":1,"passed":0,"skipped":0}'
    fi
    exit #{exit_code}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp timeout_shim do
    path = Path.expand(Path.join(["tmp", "tests", "worker", "mix_timeout.sh"]))
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, "#!/usr/bin/env bash\nsleep 5\n")
    File.chmod!(path, 0o755)
    path
  end

  defp retry_shim do
    path = Path.expand(Path.join(["tmp", "tests", "worker", "mix_retry.sh"]))
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/usr/bin/env bash
    attempts_file="attempts"
    attempts=0
    if [ -f "$attempts_file" ]; then attempts=$(cat "$attempts_file"); fi
    attempts=$((attempts + 1))
    printf '%s' "$attempts" > "$attempts_file"
    if [ "$attempts" -eq 1 ]; then
      printf '%s' 'corrupt' > _build/mut_schema/lib/demo_app/ebin/Elixir.Arith.beam
      printf '%s\n' 'not json'
      exit 1
    fi
    printf '%s\n' '{"event":"test_finished","module":"ArithTest","test":"score","status":"passed","duration_us":1}'
    printf '%s\n' '{"event":"suite_finished","total":1,"failed":0,"passed":1,"skipped":0}'
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp sha256(path) do
    :sha256
    |> :crypto.hash(File.read!(path))
    |> Base.encode16(case: :lower)
  end
end
