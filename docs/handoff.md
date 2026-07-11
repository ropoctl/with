# Handoff: D7 Eliminate-Self Flag Day and Integrated Analysis

Updated 2026-07-10 (end of day). Supersedes the morning and mid-afternoon
2026-07-10 handoffs at this path.

## Executive Status

- Branch: `main`. The D7 campaign is **committed and pushed** through
  `01a79221` (seven commits on 2026-07-10); the box_drop codegen +
  reset-on-move fixes below are the only uncommitted delta, awaiting gate
  chain six.
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

- **24 explicit `self` read receivers**: Add.add, Clone.clone,
  Contains.contains, Debug.debug_str, Deref.deref, Display.to_str, Div.div,
  Eq.eq, Error.display, Error.source, Hash.hash_value, IndexGet.get,
  IndexPlace.get, MatMul.matmul, Mul.mul, MultiIndex.multi_index, Neg.neg,
  Ord.cmp, Scoped.with_enter, Scoped.with_exit, ScopedMut.with_enter_mut,
  Sub.sub, ToString.to_string.
- **6 keyword-migrated**: IndexPlace.set (mut), IntoIter.iter (mut),
  Iter.next (mut), MultiIndexMut.multi_index_set (mut),
  ScopedMut.with_exit_mut (mut), Try.branch (move).
- **2 associated functions**: Default.default, Try.from_break.
- **Drop.drop**: was the bare-self spelling (`fn drop(self)`); migrated to
  `move fn drop() -> Unit` per §2.4 ("the only destructor receiver mode").
  All 179 `impl Drop for` sites already spelled `move fn drop()`.

**RESOLVED — this was already ruled, not an open question.** The D7 session's
ruling (recorded 2026-07-07/08, now written into `docs/decisions.md` D7 and
`docs/eliminate-self.md` §5): **in a `trait` body only `mut fn`/`move fn`
synthesise; plain `fn` keeps the explicit spelling** — with a receiver param
it is an instance contract, without one it is associated. Traits are
library-maintainer tier, so the residual ceremony lands on the right
audience. The 24 explicit read receivers and 2 plain associated contracts
above are therefore the **ruling-compliant end state**, not unfinished
migration. The ruling previously lived only in session memory
(`project_eliminate_self.md`) and was nearly re-litigated twice — hence the
doc backfill. Raw TSV: session scratchpad `trait-receivers.tsv`.

## Compiler Bugs Filed (pre-existing at HEAD, repro'd on v0.15.1)

- **#653** — unannotated fn with early `return <value>` finalizes as Unit;
  callers branch on undef; silent SIGTRAP. The new `audit:returns` catches
  the call-site shape. Workaround: explicit return annotations.
- **#654** — `if`/`while` condition types never checked
  (`SemaCheck.w` `check_if_expr` discards the cond type). This is what lets
  #653 survive to codegen.

## Verification State (end of day)

- Bridge check of the full dirty tree: `ok`. `audit:all`: **violations=0**
  (2,077,372 facts, migrated stdlib embedded).
- **First gate run:** build PASSED, **`:fixpoint` PASSED** (stage2 == stage3
  byte-identical on the migrated tree), `:test` failed only the two
  `std.build`-compiling capability tests → root-caused to the un-swept
  `lib/std/build.w` + driver files (sections above), all repaired.
- After repairs: `with build --dry-run` under full enforcement: clean; both
  capability tests: `ok` (they are cwd-sensitive — run from repo root);
  nested package builds green under the new compiler.
- **Second full gate chain (build → :fixpoint → :test) launched** with all
  repairs — the campaign completion gate. If green: the one-chain bootstrap
  (`:test-green → :last-green → :update-seed → :install-user`) is next,
  minding the reseed-convergence rule (bake the seed from the CONVERGED
  new-compiler build).
- Reduced repros: `cxstr-own.w --validate-all` ok; #653 repro flagged by
  `audit:returns` with exactly one violation (detector self-test).

### Trait-method record stride drift (root-caused + fixed, evening 2026-07-10)

With the regenerated (migrated) prelude embedded, **every user program failed
codegen** (`[type-resolve] unhandled type node …` twice, then "code
generation failed") while compiler self-compilation stayed green. Root cause:
the campaign widened the trait-method extra record from 6 to 8 slots
(parser-owned SOURCE_START/SOURCE_END spans; `TRAIT_METHOD_STRIDE = 8` in
`src/Ast.w`) and updated Parser/Sema/ComptimeTransform — but
`CodegenTraits.collect_trait_info` still hand-walked 6 slots per method, so
every method after the first read misaligned garbage (its "ret_node" was a
neighbouring method's field; the bogus node ids decoded as arbitrary
expression nodes — `explain:node:` on the live pool was the identifying
tool). The old embedding masked it: pre-migration prelude shapes never
steered the default-trait-method generator through the corrupted rows.
Fixed by reading the records through the canonical
`AstPool.trait_method_field` accessors (single source of truth; no other
hand-walk exists — swept). Note for the toolset: codegen's trait tables
(`trait_method_*`, vtables, `find_trait_method_offset`) had **no audit
coverage** — that is why five green `audit:all` runs missed it; an
`audit:trait-tables` comparing codegen's collected rows against the AST
accessors is the systematic detector to add.

### std/build.w enforcement debt (root-caused + fixed, late 2026-07-10)

First full gate run: build PASSED, **`:fixpoint` PASSED (stage2 == stage3 on
the migrated tree)**, `:test` failed on exactly two tests —
`behav_action_capability_filesystem/process` — the only tests that compile
`std.build` (they drive nested `with build` package runs). The nested child
failed with receiver/ownership enforcement errors inside
`<embedded-std>/std/build.w`. Root cause: **`lib/std/build.w` is compiled by
no gate except those two tests** (the compiler's own `build.w` is evaluated
by the DRIVER, whose old embedded std predates enforcement), so the receiver
flag-day never swept it: 17 builder methods were `mut self: Target/Build`
transition forms whose bodies consume (must be `move`), plus 26 call sites
missing `move` on consumed args (tar/gzip append helpers). Fixed by a
count-verified one-shot With repair
(`scratchpad/fix_buildstd.w`, 43 edits, probe re-check = 0 errors).

Follow-on findings while fixing: (a) the compiler's own driver files
(`build.w` root + `build/emit_c.w`, `build/sdk.w`, `build/selfhost.w`)
carried 30 more §3.8 sites — fixed by `scratchpad/fix_buildsys.w`
(count-verified). (b) The 17 flipped builder methods mutated fields through
`move self` (owned but immutable) — rewritten to the file's `var out = self`
rebind idiom (`scratchpad/fix_builders.w`). (c) **Open inconsistency:** the
plain module probe (`check` of a probe importing the module) accepted the
assign-through-owned-`self` bodies; the driver's build-wrapper compilation
rejected them ("cannot assign to field of immutable value", printed with no
span — diagnostic also needs a location). Two Sema configurations disagree
on place-mutability legality; needs a ruling on which is right and a fix for
the span-less rendering.

**Blind-spot lesson (twofold):** (1) analyzer facts and `migrate-receivers`
are computed from the `src/main.w` entrypoint — modules only reachable from
user programs (`std.build`) are invisible to audits and migrators; audit
entrypoints must also cover a probe that imports the full std surface.
(2) The gate chain's driver evaluates root `build.w` against the DRIVER's
embedded std — a reseeded compiler would have failed to run `with build` at
all. After any std/build change, verify with the NEW binary:
`<new> build --dry-run` in the repo root.

### sizeof[T] in monomorphized generics compiled to 0 (root-caused + fixed, night 2026-07-10)

Second gate run went green except `behav_arena_vec.w` — every
`arena_vec_push` silently stored nothing. Reduced to 16 lines: inside a
monomorphized generic, `sizeof[T]()` emitted `i64 0` (IR-proven: memcpy
size 0; Sema/MIR/ABI all correct). Worktree bisect exonerated the stride
fix and the Drop def flip, then proved the **pure checkpoint compiler
fails too** — the regression came in with the migration commit and gate 1's
"pass" was test-graph cache carryover (**#655**: the cache key omits the
compiler binary). Root cause: pre-campaign, codegen resolved a bare
type-param ident via the mutable `sema.resolve_type_expr` whose
specialization-recheck sidecar entries are gone under the frozen twin; the
campaign's frozen resolver returns 0 and `gen_sizeof_alignof` swallowed it
(silent-fallback `return 0`). Fix: monomorphized function emission now
establishes the instance's type-binding frame from
`sema.concrete_specialization_*` (both emitters — `gen_function_mir` AND
`gen_function_mir_mono`; the first fix attempt missed the mono emitter and
`[mono-bind]` diagnostics under `WITH_DEBUG_DTM=1` exposed it);
`resolve_type` consults the frame first for NK_IDENT/NK_TYPE_NAMED; the
three silent-0 paths in `gen_sizeof_alignof` are now loud errors naming the
function. Pinned by `behav_generic_sizeof_param.w` (expects 42). Note:
`gen_nameof`'s empty-string fallbacks are the same disease class, benefit
from the binding frame, but keep their silent "" — follow-up candidate.

### Embedded-stdlib staleness (discovered evening 2026-07-10)

`out/gen/compiler/EmbeddedStdlibData.w` had been generated by the OLD
standalone tool from **pre-migration** stdlib sources (`extend Arena`,
top-level `fn Box.as_ref(self: &Self)`, bare-self `Drop.drop`) — a
1,967-line diff against regeneration from the migrated tree. Targeted
`bridge build -o` runs do NOT regenerate it (only the full `with build`
graph's `compat-runtime-source` action does), so every binary built today
embedded the old stdlib, and the green `audit:all` validated the compiler
against the OLD prelude sources. Regenerated via
`/tmp/with-impl-kind-bridge build :compat-runtime-source --no-deps`; the
next rebuild embeds the migrated stdlib and its `audit:all` run is the
first validation of the full migrated universe (compiler + stdlib). This
staleness is also a plausible cause of finding B's method-registry delta.
Lesson: after editing `lib/std/*` in a targeted-build workflow, regenerate
`:compat-runtime-source` before rebuilding.

## RESOLVED: behav_box_drop — final two layers (night 2026-07-10, gate six pending)

Both remaining layers root-caused to the exact line and fixed; the full test
passes at runtime (`scratchpad/bdgv_run.w` executes both test fns), all bd
pins hold, `/drop-audit` 25/25 with 0 regressions, into_inner repro clean
under `--debug-alloc`.

1. **Codegen place-walk blind to transparent-box deref** (the icmp-undef
   layer). MIR was already correct (`_2.*.f6`); the three place-walk twins —
   `mir_place_projected_type` (~1204), `mir_place_ptr` (~1406), and
   `mir_place_sema_type` (~5734) in `src/CodegenDispatch.w` — resolved a
   PK_DEREF pointee only for TY_PTR/TY_REF. `Box[T]` is TY_GENERIC_INST, so
   `cur_ty` stayed 0 after the deref; the PK_FIELD arm then pointer-chased an
   extra load (landing on the payload's first 8 bytes) and failed
   `mir_resolve_field_index` → returned 0 → operand emitter substituted
   `i32 undef`. Fix: each twin resolves deref-of-std-Box to the payload type
   via `sema.type_is_std_box_inst` + `get_generic_inst_arg(_, 0)` (the
   emitted load was already landing on the payload; only the type
   bookkeeping was blind).
2. **`RK_CAST` skipped reset-on-move** (the into_inner double-drop layer).
   `Box.into_inner`'s `self as *mut T` lowered to `cast(move _1 …)` with NO
   `_1 = const zst` reset after it — `lower_cast` was the only rvalue path
   embedding an operand without `consume_moved_operand` (corpus-verified:
   the whole prelude+user MIR contains exactly one rvalue-embedded move;
   binops/unops lower non-Copy operands as copies). The moved-from box local
   stayed live, so its guarded scope-exit drop re-dropped the payload (trace
   pollution + latent double-free with the body's own `with_free`). Fix:
   one-line `consume_moved_operand(op)` in `MirLower.lower_cast`.

Also applied: `test/behavior/behav_box_drop.w` line 1 `var` → `global var`
(§9.1c; pre-verified spelling in `scratchpad/bdgv.w`).

**New findings parked while verifying (both pre-existing, proven with the
pre-fix `/tmp/with-gap2` binary):**

- `analyze <box-drop-repro> audit:all` reports 2 violations on ANY program
  instantiating `Box[T: Drop]` — `sig N: receiver requirement is not the
  finalized param[0] effect` (the sig is the `Box.drop__receiver__*`
  specialization, one past the emitted signature-fact range) and
  `call with_free … no Codegen marshalling fact` (the specialization's body
  exists in MIR but codegen inlines drop glue instead of emitting it, so its
  calls never pass the instrumented emitter). First time this shape was ever
  audited; the whole-compiler green runs never instantiate box
  specializations. Needs: exempt-or-emit decision for never-emitted mono
  drop bodies in the marshalling-coverage audit, and the receiver-req
  checker taught about the specialization sig row.
- `--debug-alloc` flags a 16-byte exit leak for ANY `global var` str that
  holds a concat result at program exit (globals are not dropped at exit) —
  isolated to `scratchpad/gleak.w`, no box involvement. Language-level
  question (should module globals drop at exit?), not a gate blocker.
- `Box.new`'s MIR emits `drop(_2.*) @ drop-before-overwrite` on the
  freshly-allocated uninit slot before `_2.* = move _1`; the runtime niche
  guard is what keeps it from firing on garbage. Correct only if
  `with_alloc` memory reads as niche — worth a deliberate zero-or-exempt
  decision.
- `Box.into_inner` MIR orders `StorageDead(_4)` BEFORE `_0 = move _4`
  (benign today — codegen ignores StorageDead — but a validator-worthy
  smell).

## PREVIOUS LOOP NOTES: behav_box_drop diagnosis trail

Gate 5 (build PASS, **fixpoint PASS — 5th consecutive**, box_as_* strata
green) surfaced `behav_box_drop`: under the current compiler it dies at the
generic-contract validator (`body=13 call=2 sig=-1 mono=0`, body sym maps
near BoxDropGuard.drop); under the PRE-autoref compiler (`/tmp/with-gap2`
≈ f68403f5) it fails differently — two "error: undefined variable"
(suspect: the module-level `var BOX_DROP_TRACE` global accessed from fns
and a Drop impl). Two failure layers to reconcile; NOT caused by the
autoref fix (pre-existing at f68403f5, cache-masked). Candidates in the
test: module-level `var` global handling, `drop(guard)` builtin lowering,
`Box.new(non-Copy payload)` drop glue, `into_inner` move-receiver chain.

## RESOLVED THIS SESSION: Box transparent-receiver autoref regression

Gate 4 (build PASS, **fixpoint PASS — 4th consecutive**, async test now
green) surfaced the next cache stratum: `behav_box_as_ptr/as_ref/
as_ref_struct` SIGSEGV (139). Diagnosis complete, fix not started:

- IR (box-ref repro): `Box.new` returns the payload ptr; caller passes it
  DIRECTLY to `Box.as_ref__receiver__324_3(ptr %0)`; the body double-derefs
  (`load ptr, ptr %0`) per its `&Self` contract → loads 42-as-address →
  caller loads from it → SEGV. One indirection too shallow — #627's exact
  class, reintroduced for the MIGRATED `impl[T] Box[T]:` synthetic-read
  receiver form (old top-level `fn Box.as_ref[T](self: &Self)` worked).
- `--dump-abi`: instantiated `Box.as_ref__receiver__324_3` param[0]
  ty=326 eff=[read] value_ref_abi=0 → COPY — the `&Self` receiver arrives
  as a plain pointer VALUE and the call site binds the box value, not the
  box slot's address. The `__receiver__` mangled instantiation path skips
  the autoref the explicit-`&Self` path performs.
- method-resolution fact: verdict=late-resolved sig=172 recv-type=324 —
  resolution is fine; the defect is call-site receiver marshalling.
- Suspect surface: `lower_receiver_with_method_autoderef_for_method` (and
  the generic `__receiver__` instantiation's receiver binding) — for a
  transparent std Box (sema_type_to_llvm special-cases Box[T] → ptr), the
  "already a pointer" shape must not be mistaken for "already a
  reference"; the decision must key on SEMA types (recv 324 = Box inst vs
  param 326 = &Box) and take the receiver PLACE address.
- **FIXED + VERIFIED (night 2026-07-10):** `MirLower.lower_generic_receiver_arg`
  wraps the generic-method receiver per the instantiated signature — autoref
  via `operand_for_place_arg` ONLY when param0 is a ref the bare-owner
  receiver lacks (`can_auto_ref_arg_frozen` gate); every other shape keeps
  the raw autoderef path, move receivers untouched. Evidence: the three box
  pins print 42/42/7; `/drop-audit` 25/25 cells, 0 regressions (its fixture
  needed a one-token D7 migration: `S.plain(self: S)` → `(self: &S)` — bare
  by-value self is now rejected, which had turned every audit cell into an
  identical check-fail); all seven prior session pins re-verified under the
  same binary; `audit:all` 2,145,022 facts 0 violations; fixpoint held.

## Remaining Work (in order)

1. ~~Trait instance/associated syntax ruling~~ — **resolved by the existing
   D7 trait carve-out** (see above); Drop.drop migrated to `move fn`;
   Phase 4's "reject explicit self" must exempt trait plain-`fn`.
2. ~~Finding B~~ — **RESOLVED (dissolved).** With the stride fix in,
   `WITH_DEBUG_DTM=1` shows build and analyze generate the IDENTICAL
   default-method set with identical metadata (BuilderError.source,
   ContextError.source on the mini probe). The original analyze-only trap
   was stride-corruption noise: analyze's fact collection interns extra
   nodes before codegen, shifting pool extras, so the misaligned 6-wide
   reads yielded different garbage per pipeline. No pipeline-selection
   divergence exists.
3. ~~Tool Gap #2~~ — **DONE (night 2026-07-10).** Sema records a
   method-resolution trace row per checked call
   (`trace_method_resolution` in `SemaCheck.w`, called from
   `check_method_call_parts`'s resolution point): receiver type, owner,
   method, inherent-registry hit, extension candidate/visibility counts,
   selected sig/fn. `analysis_collect_method_resolutions` joins each row
   against the final `resolved_call_sigs` sidecar and renders
   `kind=method-resolution` facts with verdicts: `inherent`, `extension`,
   `late-resolved`, `ambiguous-extensions`, `candidates-not-visible`,
   `outside-registry` (compiled but resolved via builtin/trait/deref/
   machinery surfaces), `unknown-method`. Requests: `select:kind=
   method-resolution`, `explain:resolution:<name>` — both
   semantic-snapshot-safe. **First field use:** proved in one query that
   `s.track(...)` carries no Sema resolution (by design), which pinned gate
   3's async-scope contract abort to MirLower's new `method_is_unresolved`
   guard dragging language machinery into the generic-contract branch —
   fixed by keeping `track` on GENERIC_CALL (codegen name-dispatches
   `with_scope_track`) while waiving only the impossible contract
   requirement. Whole-tree audit with the new facts: 2,144,752 facts,
   0 violations.
4. Focused tests per handoff D (cross-file inherent impl, scoped extend
   visibility, same-named methods on different owners, generic owner
   identity, comptime impl-kind preservation, return-ABI consistency,
   missing-backend-artifact failure, extern-no-ret Unit, unary fallback
   types, void-return default trait methods).
5. Remove temporary repair tools (`out/restore_migrated_impl_headers.w`)
   after the expensive gates pass.
6. **Expensive gates once, then bootstrap:** gate chain six (build →
   `:fixpoint` → `:test`) is IN FLIGHT with both box_drop fixes
   (`scratchpad/gates6.log`). On `GATES EXIT: 0`: `:test-green`,
   `:last-green`, then the one-chain seed update. Keep `-O1`.

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
