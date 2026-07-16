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

- #669 FIXED (6518916b): storing methods now publish their stored element
  type, so contextual enum-constructor args (slot.set(Some(x)) family) type
  correctly; task.w workarounds removed;
  behav_contextual_enum_storing_args.w pins the matrix.
- #671 FIXED (4664df67): MirLower's variant lowerings no longer let an
  ambient expected type (statement void, enclosing return type) retype a
  constructor whose variant it does not carry;
  behav_channel_enum_payload.w pins the statement-position cases.
- #672 CORRECTED + PARTIALLY FIXED (83b09fbd): channels are healthy —
  recv() returns the element directly per §14.15; the original loss/segv
  reports were probe artifacts of `.unwrap()` on non-Option values, which
  sema's raw-optional catch-all wrongly accepted (now rejected for enum
  receivers; err_unwrap_on_plain_enum.w). #672 is retitled to the real
  remaining gap: CHAN_RECV codegen discards the -1 status, so recv() on a
  closed drained channel returns an uninitialized value — needs a
  maintainer ruling on the closed-recv contract.
- DEFERRED to milestone post-v0.16.0 (maintainer ruling 2026-07-16):
  the migration campaign #675 → #673/#674/#676 (manifest-driven build
  refactor with pcre2+zlib retrofit as its completion gate, then lexbor,
  llhttp, and minicoro as manifest entries), plus all Windows work (#369,
  blocked on #676's minicoro Windows backend, and the fiber-core host
  run). None of these start before v0.16.0 ships.
- #637 FIXED (1056ff50): is_done() on a reaped (post-await) task handle
  reports done — stale generational handles name terminal fibers by
  construction. Residual noted on the issue: was_cancelled() post-reap.
- #650 (high-priority) MEASURED and PLANNED: WITH_PROFILE=1 already
  instruments every phase. Whole-compiler compile = 280s: llvm.emit_object
  156s (56%, single-threaded SelectionDAG — TM already at CodeGenLevelLess),
  llvm.optimize 34s (InstCombine on insert/extractvalue aggregate traffic),
  sema checked TWICE (frontend 23s + fresh Sema in run_mir_lower 35s),
  frontend+link negligible. Reference-compiler survey (Go/Rust/Swift/Zig,
  .reference/) posted on the issue — all four parallelize the backend.
  Execution order on the issue: (1) codegen-units (deterministic MIR-body
  partition, K threads/objects — attacks ~204s), (2) per-unit object cache
  (content-hash × compiler-fingerprint), (3) single-sema + hot-accessor
  inlining. 913cb914 landed the find_trait_decl_node cache (hygiene;
  measured noise-level — sema's cost is diffuse runtime-call overhead).
- #670 FIXED (da76b939): cross-file labels render against their own file
  and print the path (`= label <path>@L:C ...`); same-file label format
  unchanged; err_global_race_crossfile_label.w pins it.
- Windows fiber core: structurally in parity and target-validated
  (--target x86_64-pc-windows-msvc --no-prelude --validate-all), but not yet
  built or executed on a Windows host.
- Reseed and user install were performed 2026-07-15 with explicit
  maintainer approval: src/main and ~/.local/bin/with are
  v0.15.1-gf4c1c0047 (new stdlib + D9 + #669/#670 fixes), smoke-verified.
