# Share-Place Restoration — Working Plan

Restoring `docs/completed/mutability.md` (canonical; see `decisions.md` D5,
CLAUDE.md guardrail). The effect-summary layer already exists and is complete;
the drift is that lowering/ABI ignore it and hard-code move+callee-drop for every
non-`Copy` value param. **Directive (Eric, 2026-07-05): REMOVE the move-by-default
vestiges — do not gate them — so no future agent is tempted to restore them.**

## Target semantics (from the doc)

- Non-`Copy` `f(x)` default = **ephemeral shared-place alias**: callee gets a
  pointer to the caller's place, mutations are caller-visible, caller keeps
  ownership, destructor runs in the caller's scope. Callee does NOT drop it.
- `move x` = ownership transfer (callee owns + drops; caller binding invalid).
- `copy x` = independent owned value (Copy bitwise / Clone user clone).
- Call-site rule keyed on the callee's inferred effect on that param:
  - `read`/`write` → default share-place OK (read→shared borrow, write→exclusive).
  - `consume`/`escape_value` → require `move`/`copy` (plain `f(x)` is an error).
  - `escape_view` → view-origin tracking (already implemented).
- `Copy` types pass by value (unchanged). Receiver modes already aligned (Cycle 1).

## The exact sites (from the recon map)

Effect infra (Sema.w:296 constants, `sig_param_effects`, `note_*` inference,
`@[effect]` pins, view-origin) — **complete, no change.** `is_copy` (Sema.w:5207,
aggregate-Copy opt-in) — **no change.** `&T` niche — **no change.**

CHANGE (coordinated — Sema+MIR+codegen must flip together or it miscompiles):

1. **Callee drop (the pivot).** MirLower.w:11961 (`lower_fn_with_sig`) and the
   identical clause path 12068: REPLACE the unconditional non-Copy `DK_VALUE`
   drop with: drop only when `sig_param_effect(sig, pi) & (EFF_CONSUME |
   EFF_ESCAPE_VALUE)` — i.e. owned params only. Generalize the existing
   `borrowed_receiver` carve-out to "any share-place param."
2. **Call-site consume (Sema).** SemaCheck.w:12465-12483: REMOVE the
   unconditional `arg_consumed_by_value` for non-Copy and its "a plain T
   parameter consumes" comment. Invalidate the caller binding only when
   `param_eff & (EFF_CONSUME | EFF_ESCAPE_VALUE)` or the arg is
   `NK_MOVE_ARG`/`NK_COPY_ARG`. For plain non-Copy to a consume/escape_value
   param → error "requires `move`/`copy`".
3. **Call-site passing mode (MIR).** `lower_var` MirLower.w:2973 and
   `lower_call_arg` 7824: a default non-Copy value arg → share-place alias
   (address of caller's place), SKIP `consume_moved_operand`. Keep `OK_MOVE` for
   `move x`, clone for `copy x`. Plain `x` and `move x` now diverge (were both
   `OK_MOVE`).
4. **Codegen ABI.** Generalize the value-ref pointer ABI
   (`sig_value_ref_abi_params` / `fn_param_uses_value_ref_abi`, SemaDecl.w:1081)
   from "owner-type method params only" to "any non-Copy value param passed
   share-place," so the callee receives a pointer to the caller's place. Template:
   the receiver plumbing (Codegen.w:3849, 4094 `record_ref_param`). Verify the
   generic monomorphization ABI (CodegenDispatch.w:12882, 16225).
5. **Effect-driven borrow at call sites.** SemaCheck.w:~12459 arg loop: take a
   borrow keyed on `param_eff` (read→SHARED, write→EXCLUSIVE +
   `check_mutation_against_views`), mirroring `note_auto_ref_call_arg`.
6. **REMOVE the inverted vestige lints.** `should_warn_by_value_read_only_param`
   and `emit_by_value_param_returned_view_error` (SemaCheck.w:1076-1139) — their
   text ("by-value here, so the callee owns it"; "consider `&T` so callers keep
   their binding") is the precise inversion of the doc. Delete them; under
   share-place, a by-value read-only param is the correct default, not a lint.

## Phases / sequencing

- **P1** — sites 1-4 + 6 coordinated (the core + vestige removal). Build stage1
  with the old (move) seed → stage1 is share-place. Verify the doc's `append_byte`
  / `store` / `rename` examples on a scratch program.
- **P2 — self-host migration.** Run `stage1 check src/main.w`: share-place stage1
  flags every compiler-source site that relied on implicit consume/escape as
  "requires move/copy." Add explicit `move`/`copy` (compatible with BOTH the old
  seed and share-place — only NAMED non-Copy bindings passed to consume/
  escape_value params; rvalue/temp args need nothing). Iterate until clean.
- **P3** — site 5 (effect-driven borrow) + retire/rewrite drift comments.
- **P4** — `with build` → `:fixpoint` (stage2==stage3 under share-place) →
  `:test` → author doc-example fixtures (share-place write, escape needs move,
  read keeps binding, borrow conflict) → full gate → bootstrap seed.

## Self-host note

The seed is move-semantics. `move x` compiles under BOTH move and share-place, so
the P2 migration is monotone-safe: add `move`/`copy`, sources stay buildable by
the old seed, stage1(share-place)→stage2 converges, then `:update-seed`. Do NOT
write share-place-dependent compiler code (use-after-default-pass) until after the
seed is updated.
