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

## CRITICAL FINDING — effect inference must be a pre-pass (fixpoint), or share-place double-frees

The call site decides share-place-vs-move from the **callee's inferred effect**,
read from the persistent sig via `sig_param_effect(sig_idx, pi)` (SemaCheck.w
~12459, `propagate_*_param_effect` 7998/8007). But `sig_param_effects` is
populated *per function body* as it is checked (flush at SemaCheck.w:1461), with
**no pre-pass and no callee-first ordering**. Bodies are checked roughly in decl
order.

Under the current MOVE model this is harmless: the call site moves every non-Copy
arg **unconditionally** (SemaCheck.w:12470-12476), independent of the callee's
effect. The effect is only consumed for `escape_view` + transitive propagation.

Under SHARE-PLACE it is a **correctness landmine**. If caller A is checked before
callee B (forward reference, mutual recursion, or just decl order), B's
`sig_param_effect` is still 0 when A's call is checked → A treats B's owning
(`consume`/`escape_value`) param as share-place → A keeps ownership AND B drops
→ **double-free**. This would corrupt the self-host chain silently.

**Therefore the restoration MUST add a whole-program effect-inference pre-pass
that completes before any call-site share-place/borrow decision** — infer every
function's `sig_param_effects` first (a fixpoint over the call graph, because a
param's effect can depend transitively on callees' effects, and mutual recursion
needs iteration to converge; seed unknowns as the weakest effect and iterate to a
greatest fixpoint / until stable). Only then check call sites and lowering, which
now read stable, complete effect summaries. The value_ref_abi flag (below) is
also derived from the final effect, so it too must be set post-fixpoint.

This is foundational and must land **before** the coordinated flip (P1). It is
the reason the effort is release-sized rather than a few edits: the effect *brain*
exists, but it is currently a single-pass side effect of checking, not a
committed pre-pass the convention can depend on.

## Phases / sequencing

- **P0 — effect-inference pre-pass (the foundation; see CRITICAL FINDING).**
  Make every function's `sig_param_effects` complete and stable *before* any
  call-site share-place/borrow/ABI decision. Two candidate implementations:
  (a) run the existing body-check effect-inference over all fns to a fixpoint
  with call-site *decisions* suppressed, then a final decision pass; (b) a
  dedicated lightweight effect-only walk iterated to a fixpoint. Land P0 while
  the convention is still move (P0 changes nothing observable — it only makes
  effects reliably available), gate + fixpoint, so P1 builds on stable ground.
  Derive `value_ref_abi` from the final effect here too.
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

## P1 codegen findings (traced; ready to execute)

The callee side is a one-flag change; the caller side is the real work.

- **Callee (easy).** `value_ref_abi` on a param makes `declare_function_from_sig`
  emit a plain `ptr` (NOT byval) + `record_ref_param` (Codegen.w:4094-4098), so
  the callee body operates on the *pointed-to caller place* = share-place. A
  non-value_ref_abi non-Copy struct instead goes byval-indirect
  (`internal_abi_needs_indirect_param`, Codegen.w:4115) = callee gets a COPY.
  So: **setting value_ref_abi for a share-place param flips the callee to
  share-place.** Drive it from the final effect, in a pass right after
  `fixpoint_effect_flow`: for each sig param that is non-Copy, by-value (not
  ref/ptr/slice), and whose effect excludes CONSUME|ESCAPE_VALUE, call
  `set_sig_param_value_ref_abi(sig, pi, 1)`.
- **Callee drop.** MirLower.w:11961 + clause path 12068: generalize the
  `borrowed_receiver` exemption — skip `schedule_drop(DK_VALUE)` for any param
  whose effect is share-place (equivalently, whose value_ref_abi is set). Only
  CONSUME|ESCAPE_VALUE params (and move/copy args) are owned + dropped.
- **Caller (the work).** The caller passes an address for a ref param via
  `is_ref_param(fn_sym, pi)` + `mir_try_place_ptr_for_ref` /
  `get_mutable_receiver_ptr`, but this is done **per-call-path for the receiver
  (param 0)** — e.g. CodegenDispatch.w:5887 (multi-index), 12797/12899 (generic),
  13392 — NOT in one general marshalling loop. To generalize: every call path
  that pushes arguments must, for each arg `pi`, check `is_ref_param(fn_sym, pi)`
  and push `mir_operand_place_addr`/`mir_try_place_ptr_for_ref` (address of the
  caller's place) instead of the value. For an rvalue/temp argument to a
  share-place param, materialize a temp, pass its address, and drop the temp in
  the caller scope after the call. Enumerate the call-lowering paths first
  (`build_call_fn_value` and every builder of `call_args`) — this is the bulk of
  P1 and the highest miscompile risk; verify byval and sret interactions.
- **Call-site consume (Sema).** SemaCheck.w:12470-12483: stop the unconditional
  `arg_consumed_by_value` for non-Copy; mark-moved only for explicit
  NK_MOVE_ARG/NK_COPY_ARG. Add a POST-fixpoint validation pass over recorded call
  sites emitting "requires move/copy" for a plain non-Copy binding passed to a
  CONSUME|ESCAPE_VALUE param (needs call sites recorded like the effect edges).
- **Vestige lints.** Remove `emit_by_value_param_returned_view_error` (1459-1460)
  and `should_warn_by_value_read_only_param` (1469-1471) as part of the flip.
- **Generic mono.** CodegenDispatch.w:12882, 16225 recompute value_ref_abi
  structurally (`fn_param_uses_value_ref_abi`) — make them honor the effect-driven
  flag too (read the sig flag, or extend the structural check to share-place).

Estimated: P1 is the large unit; P2 (self-host migration) blast radius is unknown
until share-place stage1 runs `check src/main.w`. Both need fresh context; the P0
foundation they build on is committed and green.

## Self-host note

The seed is move-semantics. `move x` compiles under BOTH move and share-place, so
the P2 migration is monotone-safe: add `move`/`copy`, sources stay buildable by
the old seed, stage1(share-place)→stage2 converges, then `:update-seed`. Do NOT
write share-place-dependent compiler code (use-after-default-pass) until after the
seed is updated.
