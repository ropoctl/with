# Handoff: current state

Updated 2026-07-15. The #489 collection-await campaign this file previously
tracked is complete: implementation, the E0921 unblock (decisions.md D9), and
all gates are green on the commit that carries this file. There is no pending
dirty-worktree takeover state.

## What landed

- §14.11.1 collection combinators in lib/std/task.w: completion-sequence
  ordering (runtime assigns a monotone sequence at the scheduler's completion
  linearization point, Darwin and Windows cores), fail-fast fallible
  await_all, loser cancel/join for await_first/await_any, input-ordered
  all-fail errors, await_settled, empty-input contracts, and lexical
  cancellation via async fn task_cancel_point so combinator defers run on
  parent cancellation.
- Compiler prerequisites: postfix `?` reparenting over forward pipelines
  (Parser.build_forward_pipeline), same-name imported generic overloads
  (frontend tier-shadowing fix + Sema candidate registry + structural
  selection + MIR consumption of the selected node).
- E0921 (D9): async-fn concurrency evidence moved from declarations to
  call/reference sites (direct, generic, method, dyn-trait, fn-value
  coercion). An uncalled async decl — including the prelude's
  task_cancel_point and std.time.sleep — no longer poisons a program's
  mutable globals. Fixtures err_global_* now call their async fn.
- Tests: spec_ss14_11_collection_await.w, expanded
  spec_ss14_11_await_combinator_cancel_joins.w,
  behav_await_first_empty_panics.w (exit 134 + exact stderr),
  behav_pipeline.w postfix-? case, behav_generic_overload.w + lib.

## Gate evidence (this commit)

build exit 0; :fixpoint FIXPOINT; analyze src/main.w audit:all
violations=0; :test GATES EXIT 0 (866 behavior / 703 compile-error /
210 spec / all other targets green, EMIT-C smoke ok);
:test-green and :last-green recorded. Debug-allocator differential for the
new combinators: no new leaks or double-frees; all reported leaks are the
#608-pinned by-design POD-Vec backing state (see da_pod_vec.w).

## Open follow-ups

- #669: contextual generic enum arg (slot.set(Some(x))) sema-types the
  payload instead of Option[T] → codegen trap. task.w carries commented
  typed-intermediate workarounds to remove with the fix.
- #670: cross-file diagnostic labels render against the primary file's line
  table and omit the file name (made the E0921 root-cause hunt needlessly
  hard).
- Windows fiber core: structurally in parity and target-validated
  (--target x86_64-pc-windows-msvc --no-prelude --validate-all), but not yet
  built or executed on a Windows host.
- No reseed or user install was performed. :update-seed and :install-user
  remain maintainer-approval-only.
