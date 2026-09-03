defmodule Mut.Deadline do
  @moduledoc """
  Derives the host-side deadline used to kill a mutant's test port.

  The per-test `--test-timeout-ms` is handed to ExUnit as a *per test* timeout,
  but the host watchdog has to bound the *whole selected suite* for one mutant.
  Using the per-test value for both (mutalisk <= v1.29) meant a handful of
  individually valid slow tests could blow the host budget; the resulting
  `:timeout` was counted as a detection and inflated the score.

  The rule (see `host_deadline_ms/3`):

    * `suite_timeout_ms` set (config key or `--suite-timeout-ms`) —
      `suite_timeout_ms + buffer`.
    * otherwise — `max(test_timeout_ms, baseline_wall_ms * 2) + buffer`, where
      `baseline_wall_ms` is the measured wall time of the baseline test run. A
      mutant runs a *subset* of the suite, so twice the full baseline is a
      generous ceiling that still catches a genuine infinite loop.
    * with no baseline measurement available, the pre-v1.30 behaviour —
      `test_timeout_ms + buffer` — is kept.

  The buffer exists because ExUnit fires its per-test timeout first and emits a
  `MUT_RESULT` line; the host then needs time to drain the port and classify.
  """

  # 10s matches v1.8 (the old 70_000 = 60_000 + 10_000).
  @buffer_ms 10_000

  @doc "Slack added on top of the suite budget so ExUnit can report first."
  @spec buffer_ms() :: pos_integer
  def buffer_ms, do: @buffer_ms

  @doc """
  Host deadline in milliseconds for one mutant's test run.

  `baseline_wall_ms` is the measured baseline-suite wall time (`nil` when it was
  not measured).
  """
  @spec host_deadline_ms(pos_integer, pos_integer | nil, non_neg_integer | nil) :: pos_integer
  def host_deadline_ms(test_timeout_ms, suite_timeout_ms \\ nil, baseline_wall_ms \\ nil)

  def host_deadline_ms(_test_timeout_ms, suite_timeout_ms, _baseline_wall_ms)
      when is_integer(suite_timeout_ms) and suite_timeout_ms > 0,
      do: suite_timeout_ms + @buffer_ms

  def host_deadline_ms(test_timeout_ms, _suite_timeout_ms, baseline_wall_ms)
      when is_integer(test_timeout_ms) and test_timeout_ms > 0 do
    baseline_budget =
      if is_integer(baseline_wall_ms) and baseline_wall_ms > 0, do: baseline_wall_ms * 2, else: 0

    max(test_timeout_ms, baseline_budget) + @buffer_ms
  end

  @doc "One-line human description of how a deadline was derived."
  @spec explain(pos_integer, pos_integer | nil, non_neg_integer | nil) :: String.t()
  def explain(test_timeout_ms, suite_timeout_ms, baseline_wall_ms) do
    deadline = host_deadline_ms(test_timeout_ms, suite_timeout_ms, baseline_wall_ms)

    source =
      cond do
        is_integer(suite_timeout_ms) and suite_timeout_ms > 0 ->
          "suite_timeout_ms #{suite_timeout_ms}ms"

        is_integer(baseline_wall_ms) and baseline_wall_ms > 0 and
            baseline_wall_ms * 2 > test_timeout_ms ->
          "2x baseline suite #{baseline_wall_ms}ms"

        true ->
          "per-test timeout #{test_timeout_ms}ms"
      end

    "host deadline #{deadline}ms (#{source} + #{@buffer_ms}ms buffer)"
  end
end
