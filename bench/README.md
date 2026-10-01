# Benchmark tools

Run these from the repository root. They are maintainer tools and are excluded
from the Hex package. They may fetch external project sources and dependencies.
Generated reports live in ignored `bench/results/`; project work copies live
under `tmp/bench/`.

- `bash bench/run.sh --target decimal --selection static --concurrency 4`
  runs a pinned external project. Use `bash bench/run.sh --help` for the
  supported flags and targets. Target preparation may exclude tests requiring
  unavailable services; inspect those changes before interpreting a score.
- `bash bench/shard_matrix.sh --target decimal` compares focused mutation surfaces across
  projects. Read its header for parameters and prerequisites.
- `elixir bench/incremental_validation.exs` compares cold and warm verdicts on
  the demo fixture, then verifies that a source edit invalidates reuse.
- `elixir bench/equivalent_rate.exs` summarizes covered survivors in
  reports; it is a heuristic that also includes weak assertions, not proof of
  semantic equivalence.

Historical results and milestone experiments have been removed. New measurements
should record the toolchain, target revision, flags, test exclusions, and status
counts alongside wall time. Do not infer release readiness from a benchmark
score: use `bash bin/verify` and the package consumer check in the release guide.
