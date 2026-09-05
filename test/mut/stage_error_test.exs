defmodule Mut.StageErrorTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.StageError

  test "compile failures name the stage, the exit code and the captured output tail" do
    message = StageError.message(:oracle_build, {:compile_failed, 1, "** (SyntaxError) boom"})

    assert message =~ "oracle build failed"
    assert message =~ "did not compile (mix exited 1)"
    assert message =~ "Last output:"
    assert message =~ "** (SyntaxError) boom"
  end

  test "compile timeouts are reported as timeouts" do
    message = StageError.message(:schema_build, {:compile_timeout, "still compiling"})

    assert message =~ "schema build failed"
    assert message =~ "exceeded mutalisk's build timeout"
    assert message =~ "still compiling"
  end

  test "empty output adds no tail section" do
    refute StageError.message(:schema_build, {:compile_failed, 2, "  \n"}) =~ "Last output"
  end

  test "artifact-directory and project errors are actionable" do
    assert StageError.message(:sandbox_pool, {:already_exists, "/tmp/pool"}) =~
             "sandbox pool creation failed: /tmp/pool already exists"

    assert StageError.message(:oracle_build, {:not_a_mix_project, "/tmp/x"}) =~
             "is not a Mix project"

    assert StageError.message(:schema_build, :missing_user_project_root) =~
             "no user project root"
  end

  test "rescued exceptions keep their module and message" do
    assert StageError.message(:sandbox_pool, {File.Error, "no space left"}) =~
             "File.Error: no space left"
  end

  test "unknown reasons fall back to inspect" do
    assert StageError.message(:oracle_build, {:weird, [1, 2]}) =~ "{:weird, [1, 2]}"
  end
end
