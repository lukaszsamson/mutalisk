defmodule Mut.MixProjectTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "declares Mut.Application as the OTP application callback" do
    assert Mix.Project.config()[:application][:mod] == {Mut.Application, []}
  end
end
