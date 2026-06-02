# Mutator catalogue

Mutalisk mutates your source, then runs your tests against each mutated
version. A mutant that your tests catch is **killed**; one they don't is
**survived** — a gap in your test suite.

Mutators are split into two tiers. **Default-on** mutators run with a bare
`mix mut`. **Opt-in** mutators run only when you ask for them, either by
target (`--enable <target>`) or by name (`--mutators <name>`); they are
either noisier (more equivalent/false-positive mutants) or niche.

## Default-on

These are low-noise, high-signal, and have graduated past the project's
quality gate (kill ≥60%, equivalent <20%, invalid <10% across the OSS
validation matrix).

| Mutator | What it does |
|---|---|
| `Arithmetic` | swaps `+ - * /` (e.g. `a + b` → `a - b`) |
| `ComparisonBoundary` | off-by-one on comparisons (`<` → `<=`, `>` → `>=`, …) |
| `ComparisonNegation` | negates comparisons (`==` → `!=`, `<` → `>=`, …) |
| `Boolean` | swaps boolean operators (`and` ↔ `or`, `&&` ↔ `\|\|`) |
| `UnaryNot` | drops/adds `!` / `not` on boolean expressions |
| `GuardComparisonBoundary` | comparison-boundary, inside `when` guards |
| `GuardComparisonNegation` | comparison-negation, inside `when` guards |
| `GuardTypeTest` | swaps guard type tests (`is_integer` → `is_float`, …) |
| `AtomLiteral` | rotates known atoms (`:ok` ↔ `:error`, `:lt`/`:gt`/`:eq`) |
| `IntegerLiteral` | integer-literal change in pattern position (`1` → `0`) |
| `ConcatOperator` | `++` → `--` on list concatenation |
| `Pin` | unpins a pin in a pattern (`^x` → `x`) |
| `FunctionReplace` | closed-allowlist stdlib swaps (`Enum.min`↔`max`, `filter`↔`reject`, `List.first`↔`last`, `String.starts_with?`↔`ends_with?`, …) |

## Opt-in

Reach for these when you want a deeper check and can tolerate more
equivalent/noise mutants. Enable a whole target with `--enable <target>`
or pick a mutator with `--mutators <name>` (comma-separated lists; the
mutator name is the snake_case of the module, e.g. `negate_conditional`).

| Mutator | Target | What it does |
|---|---|---|
| `AttributeLiteral` | `module_attribute` | mutate module-attribute literal values |
| `IntegerLiteral` (body) / `BooleanLiteral` | `body_literal` | integer/boolean literals in function bodies |
| `StringLiteral` | `env_walker` | `""` / `"x"` string-literal swaps |
| `FloatLiteral` | `env_walker` | float-literal change |
| `NilLiteral` | `env_walker` | `nil`-literal swaps |
| `CollectionEmpty` | `env_walker` | empty a list / 2-tuple / map / n-tuple (never a struct) |
| `VariableReplace` | `variable` | swap a variable reference for another in scope |
| `BitwiseOperator` | `dispatch` | bitwise op swaps (`band`/`bor`/`bsl`/…) |
| `Membership` | `dispatch` | `in` ↔ `not in` |
| `NegateConditional` | `conditional` | `if`/`unless` condition: negate (`!cond`) / force true / force false |
| `StatementDelete` | `statement_delete` | delete a non-last statement from a function body |
| `ClauseDelete` | `clause_delete` | delete a clause from `case` / `cond` / `with` / `receive` / `try` |
| `GuardBoolean` | `guard_boolean` | `and` ↔ `or`, drop `not`, inside `when` guards |
| `PipelineDropStage` | `pipeline_drop` | drop a middle stage from a `\|>` chain |
| `MapUpdateDrop` | `map_update_drop` | `%{m \| k: v}` → `m` (drop the update) |
| `ReceiveTimeout` | `receive_timeout` | mutate `receive … after t` (t → 0 / `:infinity` / drop) |

Examples:

    # add the body-literal mutators
    MIX_ENV=test mix mut --enable body_literal

    # run only NegateConditional + ClauseDelete
    MIX_ENV=test mix mut --enable conditional,clause_delete \
      --mutators negate_conditional,clause_delete

## What "default-on" graduation means

A mutator graduates from opt-in to default-on only after it clears the
M62 gate on every target in the OSS validation matrix. The opt-in tier is
not "lower quality" — several opt-in mutators are valuable but produce
enough equivalent mutants (changes the tests *can't* distinguish) that
running them by default would muddy the headline score. See
`docs/decisions/` for per-mutator graduation rationales.
