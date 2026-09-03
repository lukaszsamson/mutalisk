defmodule Mut.DeadlineTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias Mut.Deadline

  @buffer 10_000

  test "buffer is added on top of every budget" do
    assert Deadline.buffer_ms() == @buffer
  end

  test "with no baseline measurement the deadline is the per-test timeout plus buffer" do
    assert Deadline.host_deadline_ms(10_000, nil, nil) == 10_000 + @buffer
    assert Deadline.host_deadline_ms(10_000, nil, 0) == 10_000 + @buffer
  end

  test "T25: a slow baseline widens the whole-suite host deadline" do
    # Baseline suite took 60s; a mutant runs a subset, so twice that is the
    # ceiling — the old rule (per-test timeout + buffer = 20s) would have killed
    # a perfectly healthy run and scored the timeout as a detection.
    assert Deadline.host_deadline_ms(10_000, nil, 60_000) == 120_000 + @buffer
  end

  test "a fast baseline never shrinks the deadline below the per-test timeout" do
    assert Deadline.host_deadline_ms(30_000, nil, 1_000) == 30_000 + @buffer
  end

  test "an explicit suite_timeout_ms wins over both the per-test timeout and the baseline" do
    assert Deadline.host_deadline_ms(30_000, 5_000, 600_000) == 5_000 + @buffer
    assert Deadline.host_deadline_ms(10_000, 300_000, nil) == 300_000 + @buffer
  end

  test "explain names the source of the budget" do
    assert Deadline.explain(10_000, 5_000, 60_000) =~ "suite_timeout_ms 5000ms"
    assert Deadline.explain(10_000, nil, 60_000) =~ "2x baseline suite 60000ms"
    assert Deadline.explain(10_000, nil, nil) =~ "per-test timeout 10000ms"
    assert Deadline.explain(10_000, nil, 60_000) =~ "host deadline 130000ms"
  end
end
