# Exploratory review records

These logs preserve the release-candidate exploratory testing performed with
independent GPT and Claude passes:

- `exploratory_gpt.md`: 155 public CLI/config/API findings. Current audit:
  152 fixed, one already mitigated by Hex package exclusions, and two
  intentional hidden/compiler Mix-task behaviors.
- `exploratory_claude.md`: five additional correctness/usability findings, all
  fixed with regression coverage.

The logs are repository evidence, not package documentation, and are excluded
from the published Hex artifact by the explicit `files` list in `mix.exs`.
