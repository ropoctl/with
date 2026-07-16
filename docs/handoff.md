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
- #672 CLOSED via BDFL ruling D10 (a9cd93e9): recv() -> Option[T] — Some
  delivers buffered messages first, None = closed AND drained (Rust
  semantics, Swift spelling); CHAN_RECV codegen now consumes the runtime
  status (branchless select on the tag, element written into the Option
  payload field). `for msg in rx:` is the blessed worker loop (Receiver
  is for-iterable; break/continue work; behav_channel_for_recv.w). All
  recv call sites migrated; spec §14.15 updated. Residuals in D10:
  try_recv three-state question (still unimplemented), select-arm
  binding reconciliation when select-over-channels lands. Earlier from
  the same investigation: 83b09fbd rejected unwrap on plain enums
  (err_unwrap_on_plain_enum.w).
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
  2f706c21 landed codegen-units MILESTONE 1: deterministic serial split
  (src/compiler/CodegenUnits.w; WITH_CODEGEN_UNITS env, default 1/off;
  bitcode round-trip, safe deleteBody, __wcu$ externalization, unit-0
  global ownership, multi-object link with undef-probe union, cleanup).
  Verified: K=8 compiler self-build works; unit objects byte-identical
  across rebuilds; serial unit max 50s = projected parallel LLVM wall.
  5cfc1377 landed MILESTONE 2 (threaded units): whole-compiler K=8 build
  measured 280s -> 148.5s wall; peak RSS 22.7GB; object-level determinism
  proven under threading (binary double-build diffs are PRE-EXISTING link
  nondeterminism — debug-map mtimes/UUID — present at K=1; fixpoint
  compares objects). 9879ac66 FLIPPED THE DEFAULT ON: env is explicit
  override; unset = host-aware K (<2000 MIR bodies stays single-unit;
  else cores cap 8 with a ~3GB/unit memory guard). --emit-obj and
  module-object builds stay single-object by contract, so fixpoint
  objects are whole files while the stage2/3 compilers are BUILT through
  units — the existing :fixpoint gate is a transitive unit-determinism
  proof, and it held with the default live (full battery green).
  Compiler self-build: 280s -> ~150s by default. Remaining on #650 in
  value order: unit balancing (21-63s spread on the auto run),
  single-sema (-23s), per-unit object cache (edit-loop win), lazy
  bitcode materialization (25GB peak RSS).
- #670 FIXED (da76b939): cross-file labels render against their own file
  and print the path (`= label <path>@L:C ...`); same-file label format
  unchanged; err_global_race_crossfile_label.w pins it.
- Windows fiber core: structurally in parity and target-validated
  (--target x86_64-pc-windows-msvc --no-prelude --validate-all), but not yet
  built or executed on a Windows host.
- Reseed + install re-run 2026-07-16 (maintainer-approved): src/main and
  ~/.local/bin/with are v0.15.1-g9eddd2c32 — the seed now carries codegen
  units, so every seed-driven stage build is parallel. The install
  initially produced a SIGKILL-on-exec binary (in-place overwrite left
  arm64's per-vnode signature cache stale; bytes were identical to the
  verified release; recovered via fresh-inode copy of those same bytes).
  Root-fixed in 7ba518e2: install writes a temp sibling then renames.
  Verify every future reseed with `~/.local/bin/with --version; echo $?`.
