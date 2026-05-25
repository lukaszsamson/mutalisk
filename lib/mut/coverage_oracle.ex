defmodule Mut.CoverageOracle do
  @moduledoc "Per-test-file coverage map for v1.5 selection."

  @derive {JSON.Encoder, except: []}
  defstruct by_line: %{},
            by_function: %{},
            test_runtime_ms: %{},
            fallback_static_tests: %{},
            # M64: test files whose per-file coverage collection failed
            # (exception / timeout / BEAM crash) and were degraded to static
            # selection. Each is `{path, reason}`; their tests still run for the
            # mutants they statically cover (see Mut.TestSelection.Coverage).
            degraded_test_files: [],
            collection_wall_ms: 0

  @type test_id :: {:file, Path.t()} | {:module, module()}

  @type t :: %__MODULE__{
          by_line: %{{Path.t(), pos_integer()} => MapSet.t(test_id())},
          by_function: %{{module(), atom(), arity()} => MapSet.t(test_id())},
          test_runtime_ms: %{test_id() => non_neg_integer()},
          fallback_static_tests: %{module() => [test_id()]},
          degraded_test_files: [{Path.t(), term()}],
          collection_wall_ms: non_neg_integer()
        }
end
