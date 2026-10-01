# Architecture

`Mix.Tasks.Mut` coordinates discovery, a baseline test run, mutation planning,
test selection, execution, and reporting. `Mutalisk` exposes the small runtime
helper API; modules under `Mut.*` implement the engine.

The compiler integration captures source and compiler metadata in a temporary
work copy. Planning combines syntax and compiler information to avoid generated
code and unsupported mutation sites. Mutant identities are deterministic and
independent of the chosen test-selection mode.

Schema-compatible mutations share an instrumented build. A worker chooses one
mutant through VM-global runtime state. Structural, pattern, and guard mutations
use fallback recompilation with the owning application's project configuration
and compiler options. Both engines execute tests in fresh subprocesses.

Work copies and worker sandboxes isolate mutable project files. Sources,
`mix.lock`, and `priv/` are copied; dependencies and configuration are linked
from the target project. Build outputs belong to the work copy. Between mutants,
reset restores tracked source, build, and `priv/` entries, including files,
directories, and symlinks. Timeout handling closes ports and reaps child processes.

Coverage selects test files using line or function scopes, with broader scopes
for clause-head mutations. Static selection follows module references
transitively. Unknown coverage conservatively includes affected tests for every
mutant. A whole-run static downgrade is available when collection is too slow.

Incremental history compares project, source, selected-test, and execution
configuration digests before reusing a verdict. Project fingerprints include
custom source layouts and transitive path dependencies. Reports account for
killed, surviving, timed-out, uncovered, invalid, errored, and ignored mutants.

Run `bash bin/verify` to validate the implementation. See the
[release guide](RELEASE.md) for package checks and the
[benchmark tools](../bench/README.md) for larger-project measurements.
