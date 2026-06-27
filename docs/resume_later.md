# Resume Later: Drop/Move Ownership (M7+) and the Branch-Merge Blocker

Status snapshot for continuing the `docs/drop-move-ownership.md` effort. Written
2026-06-27. The active focus has pivoted to **branch-merge soundness** (see the
companion report once written); this file is the parking record for the
drop/move slices so they can be resumed afterward.

## TL;DR

- Slices A, B, C of `drop-move-ownership.md` are **done and committed** (4 commits
  this session, each gated: build + fixpoint + fresh `:test` + test-green).
- The branch-merge soundness bug (#612) that blocked Slice D is now **FIXED** for
  `if/else` (`2a0da1d1`) and `match` (`ec65024f`, closes #579). See
  `docs/branch-merge-soundness.md`. Slice D (loops, #613) is **unblocked**.
- Other conditional constructs (if-let/while-let/`&&`/`||`/`?`) were verified
  already sound (conservative); extending the union-join to them is precision-only.
- Slice E (conditional field moves) and Slice F (generator audit + M9 matrix)
  are not started; scope notes below.

## Commits landed this session (on `main`, oldest→newest)

| Commit | What |
|---|---|
| `4da567c5` | Build memory-limit + per-target subprocess workers, **plus the worker-isolation fix** (see below) |
| `ed5a1149` | M7: runtime drop flags for conditional whole-value moves through `if` |
| `aca63335` | Runtime: free fiber pool before the debug-alloc leak walk at shutdown (**closes #609**) |
| `e0ffaa29` | M7: runtime drop flags for conditional whole-value moves through `match` |

### Worker-isolation fix (folded into `4da567c5`)
The build-memory tangent (subprocess workers for build action/test targets) had a
bug: a worker re-execs `with build :TARGET --no-deps`, which **re-evaluates
`build(ctx)` at comptime**, re-running non-idempotent ToolFs side effects
(`fs.extract_tar`'s `symlink` → `EEXIST`). Root-caused by direct lldb observation
of the worker child (backtrace into `comptime_eval_tool_build_result` →
`toolfs_extract_tar`; `rt_symlink` returned `-17`/EEXIST). Fix: a
`ComptimeEvaluator.suppress_toolfs_writes` flag set in worker mode
(`load_build_graph_from_build_w` → `comptime_eval_tool_build_result`), with a
centralized skip in `eval_toolfs_capability_method`
(`comptime_toolfs_method_is_mutating`). Reads stay live so the worker still
reconstructs the graph from the parent's outputs. Also reworded the `--no-deps`
message ("action **and test** targets") and updated `build/selfhost.w`'s
`build_w_no_deps_non_action` assertion.

## How drop/move "ought to work" (from spec + mission)

Grounding (read these): spec §2.1 (single owner), §2.2 (move invalidates source),
§2.4 (drop-on-reassignment; **partial moves from Drop types forbidden**),
§21.1 rule 3 (use-after-move forbidden), rule 7 (implicit drop is a use); §22
("false rejection of safe code is precision debt, not user ceremony"); `mission.md`
("exactly as safe as Rust", "remove the suffering").

Intent = Rust's flow-sensitive model: a value moved on some paths is *maybe-init*;
dropped only where still init (runtime drop flag when static analysis can't
decide). Accept what Rust accepts; reject what Rust rejects.

Per construct:
- **if / match**: move in one branch/arm → accept, drop only on non-moving paths
  via drop flag. **DONE** (`if` work + Slice C). Sema marks the binding MOVED
  after the move (so later *uses* are rejected — correct); MIR drop-flags only the
  *cleanup*.
- **loops**: depends on reinit.
  - moved + not reinitialized before the back-edge → **use-after-move**, reject
    (Rust rejects "moved in previous iteration"). This is the `err_loop` case;
    it must STAY rejected (a correct permanent rejection, not a missing feature).
  - reinitialized each iteration (`h = transform(h)`, §2.4's own example) → accept.
  - moved only on a path that exits (move-then-break) → accept (drop flag).
  - **Today all of these are blanket-rejected** with the misleading message
    "conditional move of Drop value requires drop-state tracking". That message is
    wrong: it advertises a mix of correct-rejections and should-compile cases as a
    missing feature.
- **fields**: §2.4 **forbids** field move-out of a `Drop` aggregate (permanent;
  the `err_move_out_vec_field_*` policy + the `drop-move-ownership.md` Decision
  Boundary). Field move-out of a **non-Drop** aggregate where the field needs drop
  IS allowed by spec — that is the only legitimate drop-flag target for Slice E.

## The blocker: branch-merge soundness (now the active task)

`VarState` is binary (LIVE/MOVED, `src/Sema.w:52`). `check_if_expr`
(`src/SemaCheck.w:7333+`) does **not merge** the two branches' move-state — it runs
them linearly and only `restore_scope_states` when a branch *diverges* (TY_NEVER,
lines 7351-7352, 7367-7370). So when one branch moves and the other reinitializes,
the linear pass ends with the *reinit* state and the move is lost:

- Test A (`if d: take(r) else: ()`; then `use2(r)`) → correctly **rejects** (nothing
  overwrites MOVED).
- Test B (`if d: take(r) else: r=make()`; then `use2(r)`) → wrongly **compiles**
  (the `else` reinit overwrites the `then` move → post-`if` says LIVE). This is a
  use-after-move on the `d`-true path. **Pre-existing soundness bug.**

This is the *under-rejection* face; #579 is the *over-rejection* face (a diverging
arm makes the owner look moved on the fallthrough). Both need real flow-sensitive
move-state merging.

## Resume plan for the drop/move slices (AFTER branch-merge is fixed)

1. **Slice D (loops)** — with a sound merge, implement the back-edge check:
   - Change loop `push_move_control_flow_context(0)` → `(1)` in `check_expr`
     (`src/SemaCheck.w` ~4839 while, ~4858 do-while, ~4876 loop; `check_for`).
   - After the loop body, snapshot-compare: a binding that was LIVE at loop entry
     and is MOVED at body-end → emit **use of moved value** (use-after-move; moved
     across the back-edge without reinit). Use `save_scope_states()` for the
     snapshot; `bind_names[idx]` → sym → `pool_resolve` for the name;
     `move_control_flow_binding_starts` gives the outer/inner boundary.
   - The existing Never-restore already makes move-then-break end LIVE → accepted.
     reinit ends LIVE → accepted. `err_loop` ends MOVED → rejected. Correct, *iff*
     the branch-merge gap is fixed (else conditional-reinit is unsoundly accepted).
   - MIR: reinit case is LIVE at loop exit → existing scope-exit drop + M4
     drop-before-overwrite handles it; no new loop drop-flag needed for the
     reinit/break subset. Add behavior + `da_*` fixtures.
   - Convert `test/compile_errors/err_loop_conditional_move_drop_value.w` to the
     correct use-after-move message (keep it a compile-error test — `err_loop`
     stays rejected, just with the right reason).
2. **Slice E (conditional field moves)** — only for **non-Drop** aggregates (spec
   §2.4). Drop-aggregate field move-out stays rejected ("partial move from Drop
   type", already correctly worded at `SemaCheck.w:18621`). The diagnostic at
   `:18627` ("conditional move of Drop field requires drop-state tracking") is the
   real target; mirror the if/match drop-flag machinery for field places, reusing
   the partial-aggregate-drop path (M4/M5).
3. **Slice F** — M8 generator-state ownership audit (the channel leak is already
   fixed; verify generator state fields holding `Drop`/`Vec[Drop]` across a suspend
   are moved in/out as owned places, not copied/zeroed); fill the M9 regression
   matrix (`drop-move-ownership.md` §Milestone 9).

## Diagnostics to fix (task #8, can be folded into D/E)
- `SemaCheck.w:5241` / `:18637` "conditional move of Drop value requires drop-state
  tracking" — now fires **only for loops** (Slice C moved if/match to `push(1)`).
  Reword to use-after-move once Slice D lands (don't reword in isolation — the
  honest message depends on the dataflow that distinguishes reinit/break from the
  genuine UAM).
- `SemaCheck.w:18621` "partial move from Drop type" — already correct (§2.4).
- `SemaCheck.w:18624` "moving a field that needs drop out of a struct is not yet
  supported (#607)…" — already honest.

## Verification protocol (every slice)
`./out/release/bin/with check src/main.w` → `with build` → `with build :fixpoint`
→ `with build :debug-alloc-tests` → `rm -rf out/test-graph && with build :test`
(fresh, so action/test targets are not cache-skipped — a real gotcha this session;
capture the **real** exit code with `( ... ; echo REAL_EXIT=$? )`, never trust a
`| tail` pipeline's exit) → `with build :test-green`. Each commit must independently
pass `:fixpoint` (verified Slice A's intermediate via a worktree with a symlinked
`.deps`).

## Relevant GitHub issues
- **#612 branch-merge move-state soundness** — test B above; the **active task**.
- **#613 loop maybe-init dataflow** — Slice D; blocked by #612.
- #579 over-rejection on diverging match arms (same missing infra as the merge gap).
- #605/#606/#607 the transitive-Drop move/drop substrate this effort continues.
- #608 POD `Vec[i32]` buffer not freed (sentinel: `da_pod_vec` expects leak count=1).
- #609 fiber pool reported as leak before shutdown — **FIXED by `aca63335`** (close it).

## Key files
- `src/Sema.w` — `VarState` (52), `bind_states`/`bind_names` (572,575),
  `scope_binding_index`, `save_scope_states`/`restore_scope_states` (3765/3772),
  `push/pop_move_control_flow_context` (3736+), `outer_binding_has_unsupported_move_context` (3750).
- `src/SemaCheck.w` — `check_if_expr` (7333+, the merge gap), `check_match_expr`
  (9332+), loop checks (4820+), `mark_moved_if_consumed` (18604+).
- `src/MirLower.w` — `lower_if` (5192), `lower_match` (7418) drop-flag machinery
  (`push_conditional_move_context`, `ensure_maybe_moved_flag_for_local`,
  `emit_conditional_value_drop_entry`, `restore_moved_value_len`).
- Tests: `test/behavior/behav_{conditional,match_conditional}_move_drop_value.w`,
  `test/debug_alloc/da_{drop,match}_conditional_move_value.w`,
  `test/compile_errors/err_loop_conditional_move_drop_value.w`.
