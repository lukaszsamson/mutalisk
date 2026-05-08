defmodule AppStartCallbackTest do
  use ExUnit.Case, async: false

  alias AppStartCallback.Repo

  test "ETS table created by start/2 is readable" do
    # Will :badarg if Application.start/2 never fired (named ETS missing).
    Repo.put(:answer, 42)
    assert Repo.get(:answer) == {:ok, 42}
  end

  test "double doubles" do
    assert Repo.double(2) == 4
    assert Repo.double(7) == 14
  end
end
