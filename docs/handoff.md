# Handoff: D7 Eliminate-Self Flag Day and Integrated Analysis

Updated 2026-07-10 (end of day). Supersedes the morning and mid-afternoon
2026-07-10 handoffs at this path.

## Executive Status

- Branch: `main`. `HEAD == origin/main == ed3ffae0`. The D7 campaign remains
  **uncommitted**; the working tree is intentionally large and dirty
  (receiver migration across 127 files plus the integrated analysis
  framework). Do not reset or broadly revert it.
- **The integrated audit gate is GREEN on the migrated tree:**

  ```
  /tmp/with-analysis-fixed analyze src/main.w audit:all
  compiler-analysis-audit: facts=2,077,276 violations=0 ok
  ```

  Key notes from the green run: method-registration methods=3765
  inherent=3765 extensions=0 **missing=0**; impl-blocks=344 extend-blocks=0
  provenance=parser-owned; receiver-projection mismatches=0;
  **return-consistency: 8,948 unit-return calls checked, 0 dest-mismatches,
  0 unit-switches** (the whole compiler tree is free of the #653 silent-undef
  class); traits=27 trait-methods=32.
- Every handoff-C completion outcome is met except the one that is a
  maintainer decision: the exact trait-receiver list is produced (below) and
  awaits the instance-vs-associated syntax ruling.
- The morning's object-emission blocker was resolved as non-reproducible
  (LLDB evidence recorded; two green builds; byte-identical binaries), and
  the backend artifact invariant now makes any recurrence loud.

## Root Causes Fixed Today (all uncommitted, in the dirty tree)

1. **`CreateAlloca(void)` trap in analyze-path codegen.** LLDB-proven
   (TypeID byte 7 at the trap). The default-trait-method fallback, the
   async-block trampoline, and the module-initializer thunk all allocated
   the return slot without the canonical void→dead-i32 policy used by the
   normal MIR emitter. Fixed at all three sites
   (`src/CodegenTraits.w` ×2, `src/CodegenDispatch.w` ×1).
2. **Extern share-place violations (`clang_getTokenSpelling` ×4).** Two-part
   fix: `impl Copy for CXToken` in `src/compiler/ClangBridge.w` (it was the
   only CX POD missing Copy — Copy PODs never enter share-place
   classification), and the share-place audits in `src/Codegen.w` now exempt
   extern "C" callees from the ref-table failure verdicts while keeping the
   facts (`value_ref_abi` on externs still truthfully records caller-retains
   ownership; the C ABI decides the mechanical shape — D5/D6).
3. **Untyped ownership-terminator place (`clang_str_to_with`).** Reduced to
   an 18-line repro: an `extern fn` with no return annotation got sig return
   `resolve_type_expr(0)` = TY_ERR, leaving the MIR call destination local
   untyped. Fixed in `src/SemaDecl.w` `collect_extern_fn` (`ret_node==0 →
   ty_void`, matching the no-meta branch) and the same guard on
   `NK_TYPE_FN`/`NK_TYPE_EXTERN_FN` resolvers in `src/SemaCheck.w` (mutable
   and frozen twins — the twins must intern identical types).
4. **`not`-condition temps typed Unit in MIR.** Discovered by the new
   return-consistency audit: `assert`/`require`/`check`/`Regex.replace_impl`
   all carried `switchInt` subjects typed Unit because
   `MirLower.fallback_expr_type` had no `UOP_NOT`/`UOP_NEGATE`/`UOP_BIT_NOT`
   cases (the `typed_expr_types` sidecar does not record unary nodes; the
   fallback is the authority). Fixed in `src/MirLower.w` mirroring
   `check_unary`'s rules, plus `NK_UNARY` added to the recorded-unit
   exemption list in `expr_type`. Functionally benign before (codegen emits
   i1 regardless) but a typed-MIR violation indistinguishable from the
   lethal class.

## New Detector: `audit:returns` (Tool Gap #4 — DONE)

Two legs, both wired into `audit:returns` and `audit:all`:

- **MIR leg** (`src/Analysis.w` `analysis_audit_return_consistency`):
  (a) call destinations typed non-void while the callee signature returns
  Unit; (b) `switchInt` subjects typed Unit — "branch on a value that cannot
  exist," which is exactly how a wrongly Unit-inferred callee (#653)
  detonates. Self-test: on the #653 repro it reports precisely the one
  genuine violation (`main`'s switch on a unit call result) and nothing else.
- **Codegen leg** (`src/Codegen.w` `audit_return_shape_contracts`, called
  from `Zcu.analyze_codegen_backend`): value-returning Sema signatures
  emitted as LLVM void without sret; extern/async/generator/sret exempt.

Renderer, dispatcher, help text, and the audit lists in `CLAUDE.md` /
`AGENTS.md` all know the new request. `docs/deep-debugging-tools.md` gained
a section of proven batch-LLDB recipes for compiler binaries.

## Trait-Receiver List (maintainer decision input — do not decide silently)

From `select:kind=declaration` trait facts on the green run, 32 trait
methods across 27 traits:

- **24 explicit `self` read receivers still spelled** (the D7 remaining
  surface): Add.add, Clone.clone, Contains.contains, Debug.debug_str,
  Deref.deref, Display.to_str, Div.div, Eq.eq, Error.display, Error.source,
  Hash.hash_value, IndexGet.get, IndexPlace.get, MatMul.matmul, Mul.mul,
  MultiIndex.multi_index, Neg.neg, Ord.cmp, Scoped.with_enter,
  Scoped.with_exit, ScopedMut.with_enter_mut, Sub.sub, ToString.to_string —
  plus **Drop.drop whose receiver mode reads `missing`** and needs its own
  ruling (Vale-style consuming destructor argues `move`).
- **6 already keyword-migrated**: IndexPlace.set (mut), IntoIter.iter (mut),
  Iter.next (mut), MultiIndexMut.multi_index_set (mut),
  ScopedMut.with_exit_mut (mut), Try.branch (move).
- **2 true associated functions**: Default.default, Try.from_break.

The open ruling: how plain `fn` inside `trait` blocks distinguishes read
instance contracts from associated functions once explicit `self` is
removed. Raw TSV: session scratchpad `trait-receivers.tsv`.

## Compiler Bugs Filed (pre-existing at HEAD, repro'd on v0.15.1)

- **#653** — unannotated fn with early `return <value>` finalizes as Unit;
  callers branch on undef; silent SIGTRAP. The new `audit:returns` catches
  the call-site shape. Workaround: explicit return annotations.
- **#654** — `if`/`while` condition types never checked
  (`SemaCheck.w` `check_if_expr` discards the cond type). This is what lets
  #653 survive to codegen.

## Verification State

- Bridge check of the full dirty tree (all fixes included): `ok`.
- `audit:all` on `src/main.w`: **violations=0** (transcript above).
- Reduced repros: `cxstr-own.w --validate-all` ok; #653 repro flagged by
  `audit:returns` with exactly one violation.
- NOT yet run: full build, `:fixpoint`, `:test` — the expensive gates are
  the next milestone once the remaining D7 items land.

## Remaining Work (in order)

1. **Trait instance/associated syntax ruling** (maintainer) using the list
   above; then migrate the 24 read receivers + Drop.drop mode.
2. **Finding B (reduced priority now the trap is fixed):** under
   `analyze_file` at least one trait default method lacks the MIR body /
   fn_values entry the build pipeline has, so the dtm fallback generates it.
   Settle with facts: trait-default methods without MIR body facts under
   analyze, cross-checked against `nm` on a built binary. Pipeline deltas to
   inspect: `compile_file` vs `compile_entry_file`,
   `analysis_partial_semantics` (only gates comptime-error abort).
3. **Tool Gap #2:** per-call method-resolution/visibility facts at
   production lookup (`method_lookup.sig_lookup` +
   `unique_visible_extension_sig`, `SemaCheck.w` ~20292) via a Sema-side
   resolution trace + collector.
4. Focused tests per handoff D (cross-file inherent impl, scoped extend
   visibility, same-named methods on different owners, generic owner
   identity, comptime impl-kind preservation, return-ABI consistency,
   missing-backend-artifact failure, extern-no-ret Unit, unary fallback
   types, void-return default trait methods).
5. Remove temporary repair tools (`out/restore_migrated_impl_headers.w`)
   after the expensive gates pass.
6. **Expensive gates once, then bootstrap:** `with build`, `:fixpoint`,
   `:test`, `:test-green`, `:last-green`, then the one-chain seed update.
   Keep `-O1`.

## Temporary Assets

- `/tmp/with-analysis-fixed` — **current working compiler** (dirty tree +
  all of today's fixes); the green-gate binary.
- `/tmp/with-impl-kind-bridge` — bridge that checks/builds the dirty tree.
- `/tmp/with-analysis-migrated`, `.lldb-built` — superseded pre-fix builds
  (kept only as byte-identical determinism evidence).
- `/tmp/with-call-key-bridge`, `/tmp/with-method-identity-bridge`,
  `/tmp/with-head-check`, `/tmp/with-receiver-migration.diff`,
  `out/restore_migrated_impl_headers.w` — unchanged from morning handoff.
- Session scratchpad: LLDB probe scripts/logs (emit-probe, trap-frames,
  trap-name), repro files (`v1m.w`, `cxstr-own.w`, variant matrix),
  `trait-receivers.tsv`, and all audit logs.

## Completion Criteria

Unchanged: no explicit receiver syntax on ordinary instance methods;
compiler-proven read/mut/move contracts; top-level functions
associated/static only; `impl`/`extend` distinct tested semantics;
collision-free method identity; frozen phases cannot re-enter mutable
checking; all integrated audits pass (**now true**); byte-identical
fixpoint; full test suite; seed updated; obsolete tools removed.
