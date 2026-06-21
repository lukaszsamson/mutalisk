defmodule Mut.ChildProcessTest do
  use ExUnit.Case, async: false

  @moduledoc "M84 retry-on-transient-failure + basic plumbing for Mut.ChildProcess."

  alias Mut.ChildProcess

  defp tmp_script_dir do
    dir = Path.join([System.tmp_dir!(), "mut_cp_test_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  test "no retry when output does not match retry_on" do
    dir = tmp_script_dir()
    script = write_script(dir, "fail.sh", "#!/bin/sh\necho 'real compile error'\nexit 7\n")

    assert {:exit, 7, output} =
             ChildProcess.run(script, [],
               retry_on: ["Failed to load module 'elixir'"],
               max_retries: 2
             )

    assert output =~ "real compile error"
    # Single invocation: real failures must NOT trigger retry.
  end

  test "retries on transient pattern; succeeds within max_retries" do
    dir = tmp_script_dir()
    counter = Path.join(dir, "counter")
    File.write!(counter, "0")

    script =
      write_script(dir, "flaky.sh", """
      #!/bin/sh
      n=$(cat #{counter})
      n=$((n + 1))
      echo "$n" > #{counter}
      if [ "$n" -lt 3 ]; then
        echo "Failed to load module 'elixir'"
        exit 1
      fi
      echo "ok on attempt $n"
      """)

    assert {:exit, 0, output} =
             ChildProcess.run(script, [],
               retry_on: ["Failed to load module 'elixir'"],
               max_retries: 3
             )

    assert output =~ "ok on attempt 3"
    assert File.read!(counter) == "3\n"
  end

  test "gives up after max_retries; returns the last failure" do
    dir = tmp_script_dir()

    script =
      write_script(dir, "always_fail.sh", """
      #!/bin/sh
      echo "Failed to load module 'elixir'"
      exit 1
      """)

    assert {:exit, 1, output} =
             ChildProcess.run(script, [],
               retry_on: ["Failed to load module 'elixir'"],
               max_retries: 2
             )

    assert output =~ "Failed to load module 'elixir'"
  end

  test "no retry on success" do
    dir = tmp_script_dir()
    counter = Path.join(dir, "counter")
    File.write!(counter, "0")

    script =
      write_script(dir, "ok.sh", """
      #!/bin/sh
      n=$(cat #{counter})
      n=$((n + 1))
      echo "$n" > #{counter}
      echo "Failed to load module 'elixir'"
      exit 0
      """)

    assert {:exit, 0, _} =
             ChildProcess.run(script, [],
               retry_on: ["Failed to load module 'elixir'"],
               max_retries: 5
             )

    # success short-circuits retry, regardless of output matching retry_on.
    assert File.read!(counter) == "1\n"
  end

  test "absolute deadline kills a chatty process that never goes quiet (R2)" do
    dir = tmp_script_dir()

    # Emits a line every 50ms forever — under an inactivity timer this never
    # trips the deadline; under an absolute deadline it is killed on budget.
    script =
      write_script(dir, "chatty.sh", """
      #!/bin/sh
      while true; do
        echo "still working"
        sleep 0.05
      done
      """)

    started = System.monotonic_time(:millisecond)
    assert {:timeout, output} = ChildProcess.run(script, [], timeout_ms: 300)
    elapsed = System.monotonic_time(:millisecond) - started

    assert output =~ "still working"
    # Killed near the budget, not running unbounded.
    assert elapsed < 3_000
  end
end
