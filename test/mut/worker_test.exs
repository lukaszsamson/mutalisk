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
    mix = timeout_shim()

    result = Worker.run_schema(%Sandbox{id: 1, path: path}, 7, [], mix_path: mix, timeout_ms: 50)

    assert result.status == :timeout
  end

  defp fake_sandbox(name) do
    path = Path.expand(Path.join(["tmp", "tests", "worker", name]))
    File.rm_rf!(path)
    File.mkdir_p!(path)
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
end
