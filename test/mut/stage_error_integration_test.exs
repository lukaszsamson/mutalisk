defmodule Mut.StageErrorIntegrationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  T27: the setup stages return `{:error, reason}` for ordinary user mistakes.
  `mix mut` used to pattern-match them as `{:ok, _}`, so a project that does not
  compile blew up as a bare `MatchError`. These tests pin the real error shapes
  and assert `Mut.StageError` turns each into a message a user can act on.
  """

  alias Mut.StageError

  test "a non-Mix directory fails the oracle build with a readable message" do
    root = tmp_dir("not-a-project")
    File.mkdir_p!(root)

    assert {:error, {:not_a_mix_project, _path} = reason} =
             Mut.OracleBuild.run(root, force: true, root: root)

    message = StageError.message(:oracle_build, reason)
    assert message =~ "oracle build failed"
    assert message =~ "is not a Mix project"
    refute message =~ "MatchError"
  after
    File.rm_rf!(tmp_dir("not-a-project"))
  end

  @tag :integration
  test "a project with a syntax error fails the oracle build with the compile output" do
    root = tmp_dir("syntax-error")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    project_root = Path.join(root, "app")
    File.cp_r!(Path.expand("test/fixtures/demo_app"), project_root)

    File.write!(
      Path.join([project_root, "lib", "broken.ex"]),
      "defmodule DemoApp.Broken do\n  def oops do\n"
    )

    assert {:error, reason} = Mut.OracleBuild.run(project_root, force: true, root: root)
    assert match?({:compile_failed, _exit_code, _output}, reason), inspect(reason)

    message = StageError.message(:oracle_build, reason)
    assert message =~ "oracle build failed"
    assert message =~ "the project did not compile"
    assert message =~ "Last output:"

    # Mix.raise/1 turns exactly this into a Mix.Error, never a MatchError.
    assert_raise Mix.Error, fn -> Mix.raise(message) end
  after
    File.rm_rf!(tmp_dir("syntax-error"))
  end

  defp tmp_dir(name), do: Path.expand("tmp/stage_error_#{name}")
end
