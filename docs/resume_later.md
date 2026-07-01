# Resume Later: Drop/Move Ownership — current state under the niche

Resume record for the `docs/completed/drop-move-ownership.md` effort. **Updated
2026-06-30 to the niche design.** The drop/move substrate is no longer built on runtime
drop flags + static drop elaboration; it is built on the **niche** (reset-on-move
+ the guarded drop), which shipped as Stages 1–6 and is now merged to `main` and
installed. This file records what that means for the remaining slices.

## The design now (read these first)

- Canonical: **spec §2.5** (Generational Ownership), **impl-notes §2.6**
  (implementation), and the niche memory `project-generational-ownership-niche`.
- **Owner safety is a runtime fact, not a static proof.** A move blanks its
  source (owning pointer → null, container → empty); a drop checks the reset
  sentinel (`rt_value_is_zero`) and skips a blanked value. Double-free is
  impossible by construction.
- **Sema move-checking is the diagnostic/optimizer layer, not the safety
  mechanism.** The branch-merge union-join (#612), the loop back-edge dataflow
  (#613), and the never-moved guard-elision optimizer (Stage 4,
  `MirBody.ever_moved_locals`) all live here. A bug in any of them can over-reject
  or cost a redundant store — never leak or double-free.
- **The M7 runtime drop-flag scheme and the static dead-drop elaboration are
  RETIRED** (spec §2.5.2 forbids reintroducing them). Conditional moves
  (if/match/loop) route entirely through the niche. Do not rebuild
  `ensure_maybe_moved_flag_for_local`, `--dump-drop-flags`, etc. — they are gone.

## Done (closed)

- **#612 / #579** branch-merge move-state soundness — union-join for `if`/`match`.
  Analysis + fix record: `docs/completed/branch-merge-soundness.md`.
- **#613** loop maybe-init dataflow — sound for `while`/do-while/`loop`/`for`
  (back-edge UAM, continue-carried move, break accumulator).
- **#614** reassign-after-move double-drop — fixed by reset-on-move (the niche),
  not by the static-elaboration pass the old analysis recommended. Record:
  `docs/completed/drop-elaboration-soundness.md`. `da_reassign_after_move` is green
  and the loop reinit fixtures now assert exact drop counts.
- **#609** fiber pool reported as a leak at shutdown — drained before the ledger
  walk.
- **M7 conditional whole-value moves** (if/match/loop) — sound via the niche.
- **Slice E — conditional *field* moves** — closed by the **field-place niche**.
  A Drop-bearing field moved conditionally out of a non-Drop struct is blanked on
  the moving path (`MirLower.consume_moved_operand` records the field place in
  `pending_reset_field_places` when `field_move_in_branch > 0`; flushed scoped per
  branch in `flush_pending_resets_since`), and the owner's existing guarded
  per-field drop (`rt_value_is_zero`) skips the blanked field — with the base local
  marked `ever_moved` so the Stage-4 elision keeps the owner's guard (else the
  blanked field's drop null-derefs). The reset is scoped to CONDITIONAL moves (the
  `field_move_in_branch` counter, inc'd around if/match/while/loop bodies); an
  unconditional field move stays statically moved and the owner's partial drop
  skips it without a reset (preserved drop-plan, no dead store). The
  `SemaCheck.w:18691` rejection is lifted. Fixtures:
  `behav_conditional_field_move_drop` (if + match), `da_conditional_field_move`.
  Field move-OUT of a `Drop` aggregate stays forbidden (§2.4;
  `err_move_out_vec_field_*` + `SemaCheck.w:18685/18688/18741`).
- **Slice F — M8 generator/async-state ownership audit** — done; the async path is
  sound. With's async is fiber-based, so a `Drop` value live across a suspend
  (await) stays on the fiber stack (no copy/zero of "generator state") and the
  niche drops it normally — on normal completion, on move-after-await, and on
  cancellation (the loser of a `select await` unwinds and drops its live locals).
  Verified for a `Drop` struct and a `Vec[Drop]` across a suspend. Fixtures:
  `da_async_drop_across_await`, `behav_async_drop_across_await`,
  `da_async_cancel_drops_live`. (No copy/zero hazard — the `gen_zero_operand` the
  plan worried about is the aggregate-init/reset helper, not used in async lowering.)
- **Field-read drop suppression** — fixed. `cancel_scheduled_value_drop_for_receiver_expr`
  (`MirLower.w`) marked *any* field-access RHS of a `let` moved (the #606 self-aliasing
  case), including a plain **Copy** field read (`let _ = r.ptr`). Marking a Copy field of
  a `Drop` struct moved degraded the owner's whole-value `Drop` into a partial drop that
  emits nothing (its fields are not individually needs-drop) → the user `Drop` was
  bypassed → leak. Fix: skip the mark when the field type is `Copy` (a Copy read carries
  no owned buffer; only the non-Copy aliasing read does). Root-caused at the instruction
  level (`--dump-mir` showed `StorageDead(_2)` with no `drop(_2)` after `_4 = copy _2.f8`).
  Fixtures: `da_field_read_keeps_drop`, `behav_field_read_keeps_drop`; #606 aliasing
  (`behav_mut_self_field_assign_vec_tail`) still passes.

## Genuinely remaining

1. **Deeper partial-move precision (A6/A7/A8 — separate future phases, not the niche
   core).** Nested aggregate-in-struct-field drop (A6), wildcard/discard element drop in
   irrefutable destructure (A7), and precise per-element partial-extraction tracking to
   replace the conservative whole-base consume (A8). See `docs/phase_8_handoff.md` and
   `docs/completed/a5_handoff.md`. (One A5 coverage gap noted while archiving: the
   `behav_mut_self_vec_owner_receiver.w` test from the handoff's restore list was never
   restored; the other two A5 fixtures exist and pass.) The niche plus conditional
   whole-value and field moves (Slices
   A–F) and the field-read drop fix are complete; A6/A7/A8 are precision refinements
   (the current whole-base consume is conservative/safe), not soundness gaps.

## Verification protocol (every change)

`./out/release/bin/with check src/main.w` → `with build` → `with build :fixpoint`
→ `with build :debug-alloc-tests` (the soundness oracle) →
`rm -rf out/test-graph && with build :test` (fresh) → `with build :test-green`.
For conditional moves the `da_*conditional_move*` fixtures must show `leak count=0`
and never `DOUBLE FREE`.

## Key files (current)

- `src/Sema.w` / `src/SemaCheck.w` — move-checking diagnostic: `check_if_expr`,
  `check_match_expr`, the loop dataflow (`finalize_loop_move_state`,
  `check_loop_continue_carried_move`, `capture_loop_break_move_state`), the
  field-move rejections (`:18685`–`:18741`).
- `src/MirLower.w` — the niche: reset-on-move recorded at the single
  `pending_reset_locals.push` site (also marks `ever_moved_locals` for the Stage-4
  elision); the guarded drop in `emit_drop_entry`.
- `src/Mir.w` — `MirBody.ever_moved_locals` (the elision set).
- `rt/rt_core.w` — `rt_value_is_zero` (the reset-sentinel check); per-slot
  `with_slotmap_*` generation for §6 handles.
- Tests: `test/behavior/behav_{conditional,match_conditional}_move_drop_value.w`,
  `test/debug_alloc/da_{drop,match}_conditional_move_value.w`,
  `test/compile_errors/err_loop_conditional_move_drop_value.w`,
  `test/compile_errors/err_move_out_vec_field_*.w`.

## Open issues

- #617 — the parallel-workspace corruption is root-caused and fixed (three
  thread races in the comptime `parallel()` compile path; commits `e8a01e48` +
  `da6176fb`). The issue stays open only for the original, never-reproduced
  `with get` zlib symptom.
- #607/#605/#606 — the transitive-Drop move/drop substrate this effort continued;
  Vec drop and aggregate content drop now ride the niche.
