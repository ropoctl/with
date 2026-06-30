# Resume Later: Drop/Move Ownership — current state under the niche

Resume record for the `docs/drop-move-ownership.md` effort. **Updated 2026-06-30
to the niche design.** The drop/move substrate is no longer built on runtime
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

## Genuinely remaining

1. **Slice E — conditional *field* moves (rejection VERIFIED load-bearing).**
   `SemaCheck.w:18691` rejects "conditional move of Drop field requires drop-state
   tracking" (`:18701` is the value form). **This is not a stale over-rejection.**
   Probe (2026-06-30): lifting it and running a conditional field move out of a
   non-Drop struct under `--debug-alloc` produced a **`DOUBLE FREE`** on the moved
   path. Cause: `consume_moved_operand` (`MirLower.w`) records reset-on-move only
   for **whole locals** (`pending_reset_locals.push`, in the `local_id >= 0`
   branch); a field place gets `mark_place_field_moved` with **no reset**, so a
   conditionally-moved field keeps its bits and the owner's scope-exit drop frees
   it a second time. Closing Slice E therefore needs the **field-place niche**:
   blank a conditionally-moved field on the moving path, and make the owner's
   per-field drop guarded (`rt_value_is_zero`) so it skips the blanked field — the
   field analogue of the whole-value niche. That is real work, **not** a lift, and
   **not** a rebuilt field-level drop flag (retired). Field move-OUT of a `Drop`
   aggregate stays forbidden (§2.4 policy; `err_move_out_vec_field_*` +
   `SemaCheck.w:18685/18688/18741`).
2. **Slice F — M8 generator/async-state ownership audit + M9 matrix gaps.** No
   generator-state Drop fixtures exist yet (`da_*gen*` is empty). Confirm generator
   state fields holding `Drop`/`Vec[Drop]` across a suspend are moved in/out as
   owned places (the niche resets them on move), not copied or zeroed. The M9 `da_*`
   matrix is otherwise well-populated (38 drop fixtures).

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

- #617 — pre-existing, layout-sensitive flaky corruption in cli-selfhost cases
  (unrelated to drop/move; see memory `project-617-flaky-cli-selfhost`).
- #607/#605/#606 — the transitive-Drop move/drop substrate this effort continued;
  Vec drop and aggregate content drop now ride the niche.
