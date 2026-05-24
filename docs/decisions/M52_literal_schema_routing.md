# M52 — schema-route the literal catalogue + literal stable-id migration

**Date:** 2026-05-24
**Decision:** Route scalar literals through the **schema engine**; recognize
case-gate-illegal positions in `Mut.SchemaPlacer` and **reroute them to the
fallback engine** rather than enumerate-and-skip in discovery or hard-fail the
build. Accept a **one-time stable-id migration** for scalar literals;
non-literal IDs are held byte-identical.

## Problem

Pre-M52, scalar literals ran only on the fallback engine (per-mutant source
patch + recompile). The schema engine (one instrumented build, runtime mutant
selection) was reserved for dispatch/guard. Bringing literals onto schema
needs a literal's `ast_path_hash` to equal the **plain-AST** positional path
that `SchemaPlacer` traverses — but the `literal_encoder` wraps keyword keys
and collections, diverging the encoded spine (`:do_block` → `:literal`) from
the plain spine. A pure path-based approach is structurally blocked.

## Resolution

1. **Marked-encoder + 2-pass normalization** (`Mut.AstWalk`,
   commit 1/2). Parse with `literal_encoder: [__mut_lit__: true] ++ meta`,
   then unwrap marked blocks wrapping collections (pass 1) and in keyword-key
   position (pass 2). The non-literal spine becomes plain-identical (17/17
   dispatch paths matched); marked scalar-value blocks remain leaves whose
   path equals the bare literal's plain-AST path.

2. **Reroute-to-fallback for unplaceable literals** (commit 2/2). A `case`
   gate is illegal in some positions: **bitstring segments** (`<<x::128>>` —
   sizes/units/types must be compile-time constants) and **clause-head
   patterns** (`->`/`<-` head: `case`/`fn`/`with`/`try`-`catch`-`rescue`/
   `receive`). Enumerating every such context in discovery is fragile
   (whack-a-mole across crypto/binary code), and placing them anyway
   hard-fails the schema build (the `CompileRollback` per-file invalid budget
   is exhausted by the volume). Instead, `SchemaPlacer.refused_context/1`
   recognizes these positions and the existing `SchemaBuild.reroute_refused/2`
   moves them to `engine: :fallback`. This is the PLAN's "literals that cannot
   be schema-placed fall back as today," made deterministic (no budget spend).

   The clause-head rule deliberately **over-refuses** `cond` arrow heads
   (boolean expressions, not patterns) — they route to fallback, which is
   always safe, so precision there isn't worth the complexity.

## Stable-id migration (one-time)

Scalar literals now carry a plain-AST `ast_path_hash` (previously
`ast_path=[]` + byte-span identity). Their `stable_id`s therefore change
**once**. Non-literal IDs (dispatch/guard/attribute) are content-hashed
independently of literal routing and **do not change** — verified by the
demo_app stable-id golden (33 IDs) and a 64-ID byte-identity check on
plug_crypto.

## Validation

`plug_crypto` (crypto/bitstring-heavy `message_encryptor.ex`) with
`atom_literal` enabled: schema build succeeds, **Invalid: 0**, 5 atoms
execute via schema, the two `catch :error, :notsup ->` heads reroute to
fallback. `bin/verify` green across all layers (lint, unit, dialyzer,
golden, integration, e2e). Broad multi-target validation is M55.
