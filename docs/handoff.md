# Handoff: final spec-suite debt, gates, and reseed

Rewritten 2026-07-12 as a self-contained takeover document. Read
`AGENTS.md` and `out/project-state.md` first. This document supersedes the
older D7 session log; git history retains that version at `ecd60f5c`.

## 1. Executive status

- Branch: `main`.
- HEAD: `10f7771e Sema: complete generic call contracts`.
- Tracked working tree when this handoff was written: only
  `docs/handoff.md` is modified. The compiler/stdlib work is committed.
- Do not reseed, update the installed compiler, or run `:install-user`
  without explicit maintainer approval.
- The bridge `/tmp/with-impl-kind-bridge` is still a deviant seed lineage.
  A binary built directly by it is generation 1 and is not trustworthy for
  semantic or runtime verdicts. Build two generations and trust generation 2.
- No new tools are needed. The next work is compiler/runtime/test debt, not
  missing tooling.

The last completed full-suite inventory, before `10f7771e`, was:

- behavior: 850/850 pass
- compile-error: 697/697 pass
- codegen: 16/16 pass
- spec: 196/209 pass, 13 fail

`10f7771e` fixes five of those 13 spec files. All five pass individually
under a fresh generation-2 compiler, so eight failures are expected to remain,
but that expected count is not yet a completed full-suite verdict.

A post-commit current-driver `:test` run was started and then interrupted at
the user's request while it was rebuilding stage 1. It did not reach any test
verdict. The background graph was stopped cleanly. Do not report that run as
test evidence.

## 2. Provenance rule: generation 2 only

`/tmp/with-impl-kind-bridge` descends from a dirty-tree compiler known to
miscompile current sources. Proven bad regions include autoderef
has-field/has-method decisions, transparent Box handling, and noalias guard
code. A generation-1 crash, diagnostic, timing, or runtime result is not
evidence about the source.

For every compiler/stdlib source change:

```
/tmp/with-impl-kind-bridge build src/main.w -O1 -o /tmp/change-g1
/tmp/change-g1 build src/main.w -O1 -o /tmp/change-g2
/tmp/change-g2 run test/spec/<focused-test>.w
```

Trust only `/tmp/change-g2`. A one-generation build answers only “does the
source compile at all?”

Current useful binaries:

- `/tmp/with-impl-kind-bridge`: deviant bridge; never trust its behavior.
- `/tmp/gc-contract6-g1`: generation 1 for the source now committed as
  `10f7771e`.
- `/tmp/gc-contract6-g2`: trusted generation 2 for that source.
- `/tmp/gate-generic-contract-driver`: copied from the green full build
  before the commit was created. It contains the committed source changes, but
  its embedded version string names the preceding commit because the commit
  happened after the gate.
- `out/release/bin/with`: same caveat as the preceding driver. Re-run the
  graph before treating its version/provenance as current HEAD.

The bridge-driven graph gate remains:

```
WITH=/tmp/with-impl-kind-bridge /tmp/with-impl-kind-bridge build
WITH=/tmp/with-impl-kind-bridge /tmp/with-impl-kind-bridge build :fixpoint
cp out/release/bin/with /tmp/gate-driver
WITH_MEMORY_LIMIT_BYTES=0 WITH=/tmp/gate-driver /tmp/gate-driver build :test
```

The test step must use the newly copied release driver. An older driver can
silently use an older test runner/cache policy.

## 3. Work completed in this takeover

Commits after the old handoff:

- `2f94cee6` — prefer same-module extensions during lookup.
- `9288ad94` — infer generic struct fields from concrete siblings.
- `dc20cc8f` — copy referenced Copy values at calls.
- `dd337352` — audit trait-table contracts.
- `42697b3b` — permit opaque share-place receivers.
- `5cf5eac9` — associate Builder constructors with their source type.
- `10f7771e` — complete generic call contracts and the related async/stdlib
  corrections described below.

Before `10f7771e`, the three behavior failures named by the old handoff were
fixed; the completed current-driver inventory reached behavior 850/850.
Trait-table auditing was also implemented and folded into `audit:all`.

### 3.1 Synthetic generic-call contracts

Changed files:

- `src/Sema.w`
- `src/SemaCheck.w`
- `src/MirLower.w`

Synthetic calls did not pass through the ordinary resolved-call path, so MIR
could emit `GENERIC_CALL` without a concrete signature/monomorph symbol:

- BTreeSet/BTreeMap literal insertion
- BTree comprehensions
- user-defined `Try.branch` and `Try.from_break` for `?`

Sema now records dedicated sidecars:

- `try_branch_sigs` / `try_branch_mono_syms`
- `try_from_break_sigs` / `try_from_break_mono_syms`
- `btree_insert_sigs` / `btree_insert_mono_syms`

`Sema.concrete_owner_method_sig` is the single helper used to specialize an
owner method. MIR consumes those exact contracts through
`lower_resolved_call_with_operand_args_contract`.

`MirBuilder.generic_call_uses_codegen_dispatch` is now the single decision
point for true codegen-dispatched machinery. The exemptions are intentionally
narrow: Task/scoped-task/join handles, channel endpoints, Atomic, and
unrecorded track/spawn/join/from_int plus Atomic static `new`. Ordinary user
generic calls require a recorded contract even when their names collide with
machinery names.

Generic free functions on the right side of a pipeline are now specialized
with the pipeline LHS prepended to both the type and argument-node vectors.
This is required by `tasks |> await_all`.

### 3.2 Async signature normalization

Changed files:

- `src/SemaDecl.w`
- `src/SemaCheck.w`

Root cause: `check_fn_body_concrete` built a generic async specialization
signature from the raw declared return type, while normal declaration
collection exposed `Task[T]`. The same source function therefore had two
return contracts.

`Sema.fn_signature_return_type(flags, declared_ret_type)` is now the single
normalizer. It is used by ordinary declaration collection, trait effective
returns, concrete generic body checking, and generic call return typing.

### 3.3 Generic substitution state restoration

Changed file:

- `src/TypeLayout.w`

The exact bad function was
`type_layout_generic_struct_field_type`. It called
`setup_generic_inst_substitution`, whose clear/setup replaced the caller's
active substitution vectors, then returned without restoring them.

LLDB proof from the nested `await_settled` repro:

- outer environment entered with `[T=i32, E=str]`
- while checking the nested Result field, the vector became only
  `[T=Result[i32,str]]`
- a hardware watchpoint caught the length transition `2 -> 1` at the old
  `TypeLayout.w:52` call to `setup_generic_inst_substitution`
- call chain: `type_needs_drop -> check_struct_literal -> check_bodies`

The helper now clones both substitution vectors, uses a single-exit shape, and
restores them before returning. This removed the erroneous
`Result[Result[i32,str],str]` type.

### 3.4 Await combinators suspend in the caller

Changed file:

- `lib/std/task.w`

The five collection combinators were declared `async fn`, which made their
surface return `Task[...]`. The normative §14.11 examples use
`tasks |> await_all` without a trailing `.await`, and their stated returns
are direct `Vec`, `Result`, or `T`.

With permits a plain `fn` to suspend; `async fn` means spawn immediately
and return a Task. The following declarations are now plain `pub fn`:

- both `await_all` overloads
- `await_first`
- `await_any`
- `await_settled`

After this stdlib edit the embedded prelude was regenerated. Future
`lib/std/**` edits must do the same:

```
WITH=/tmp/change-g2 /tmp/change-g2 build :compat-runtime-source --no-deps
```

Skipping this step makes focused tests and audits compile the old embedded
stdlib.

## 4. Verification evidence for 10f7771e

The following unchanged spec files all ran successfully under
`/tmp/gc-contract6-g2`:

- `test/spec/spec_ss04_3c_btree_collection_literals.w`
- `test/spec/spec_ss13_6_comprehensions.w`
- `test/spec/spec_ss11_7_try_trait.w`
- `test/spec/spec_ss14_17_1_atomic_generic.w`
- `test/spec/spec_ss14_11_await_combinator_cancel_joins.w`

Compiler analysis:

```
/tmp/gc-contract6-g2 analyze src/main.w audit:all
```

Verdict: 2,165,080 facts, 0 violations, `ok`.

Mandatory drop audit:

```
python3 .claude/skills/drop-audit/audit.py --with /tmp/gc-contract6-g2
```

Verdict: 25 cells, 0 failures, 0 regressions.

Full graph:

```
WITH=/tmp/with-impl-kind-bridge /tmp/with-impl-kind-bridge build
WITH=/tmp/with-impl-kind-bridge /tmp/with-impl-kind-bridge build :fixpoint
```

Verdicts:

- full build exited 0 and wrote `out/release/bin/with`
- fixpoint printed `FIXPOINT` and exited 0
- `git diff --check` passed before the commit

The full suite has not been completed after `10f7771e`; see §1.

## 5. Build-timeout incident: do not “fix” the timeout

The first full-build attempt timed out while stage 1 was compiling stage 2 at
the hard 600-second graph limit. Both stage logs were empty. The exact command
from `out/.build-state/stage2.effects` was:

```
out/bootstrap/bin/with-stage1 build out/gen/main.w -O1 \
  -o out/stage/bin/with-stage2.tmp
```

Important evidence:

- `src/main.w` and `out/gen/main.w` differed only in the version string.
- A slow stage-1 run did eventually produce a stage-2 binary with exactly the
  same Mach-O section sizes as a trusted gen-2 compile. The byte differences
  began in UUID/output-path metadata, not excess code sections.
- Trusted gen-2 compiled the identical generated source in 378.08 seconds
  wall / 369.80 seconds user, peaking around 17.6 GB RSS.
- A pressured stage-1 diagnostic took 1004.62 seconds wall but only 314.64
  seconds user, showing severe off-CPU/resource pressure rather than a loop.
- A clean rerun of the actual graph published stage 2 in roughly seven
  minutes, then completed stage 3 and the release build; fixpoint passed.

Conclusion: this was transient resource pressure amplified by the deviant
generation-1 compiler, not a source/code-size regression. Do not raise the
600-second timeout and do not change optimization. `-O1` remains mandatory.

Timing lesson: attaching LLDB during a timing run suspends or perturbs the
process and destroys wall-time evidence. Use LLDB for exact branch proof, not
for performance timing.

Analysis-query lesson: `summary:kind=specialization` is not classified as a
semantic snapshot and proceeds into MIR. `select:kind=specialization` returns
at sema, but this compiler registers the concrete specialization queue during
MIR preparation, so the early query correctly returned zero rows.

## 6. Exact prior 13-file spec inventory

The captured prior failures remain under `out/test-graph/native-spec-tests`.
The 13 files were:

1. `spec_ss03_7_box_auto_deref.w`
2. `spec_ss04_3c_btree_collection_literals.w`
3. `spec_ss07_with_blocks.w`
4. `spec_ss10_8_error_trait.w`
5. `spec_ss11_6_trait_default_methods.w`
6. `spec_ss11_7_try_trait.w`
7. `spec_ss13_6_comprehensions.w`
8. `spec_ss14_11_await_combinator_cancel_joins.w`
9. `spec_ss14_17_1_atomic_generic.w`
10. `spec_ss14_17_mutex_generic.w`
11. `spec_ss14_17_rwlock_generic.w`
12. `spec_ss16_10_null_pointer_literal.w`
13. `spec_ss16_7_callback_context.w`

Items 2, 6, 7, 8, and 9 pass under generation 2 after `10f7771e`.
The remaining eight are described below.

## 7. Remaining expected failures

### 7.1 Box auto-deref through nested references — compiler bug

Test and spec:

- `test/spec/spec_ss03_7_box_auto_deref.w`
- §3.7, `docs/with-specification.md:841`

Only the nested-reference case is known to fail:

```
let r = &user
let rr = &r
assert(rr.name == "Barbara")
```

Captured LLVM contains:

```
%4 = icmp eq i32 undef, %str ...
```

LLVM verification then fails for
`test_box_auto_deref_through_reference`. Direct Box field and method access
are separate cases in the same file.

Strong first-breakpoint candidate, not yet debugger-proven:

- `MirLower.w:4343` returns immediately from
  `lower_field_base_place_for_field` whenever recorded autoderef steps exist.
- For `&&Box[T]`, the recorded steps remove the two references and land on
  `Box[T]`.
- That early return bypasses the transparent-Box payload projection at
  `MirLower.w:4370-4377`.
- The resulting field place is typed/projected as the Box rather than its
  payload, eventually reaching the silent `i32 undef` class.

Do not patch from that characterization alone. Confirm the exact branch with:

```
WITH_DEBUG_DEREF=1 WITH_DEBUG_BOXWALK=1 /tmp/change-g2 check \
  test/spec/spec_ss03_7_box_auto_deref.w
/tmp/change-g2 check --trace-place test/spec/spec_ss03_7_box_auto_deref.w
```

Then break in `lower_field_base_place_for_field`/the place projection that
produces the bad type. Existing traces are `[deref-walk]` in
`SemaCheck.w`, `[boxwalk]` in `MirLower.w`, and `[boxsym]` in
`Sema.w`.

Separately, codegen still contains silent `wl_get_undef(i32)` fallbacks. Do
not use one to make this compile. The real fix is the place/type path, and any
impossible fallback encountered should become a loud non-zero failure.

### 7.2 &Concrete to &dyn Error — compiler coercion bug

Test and spec:

- `test/spec/spec_ss10_8_error_trait.w`
- §10.6 context contract around
  `docs/with-specification.md:4608-4619`
- §10.8 error declarations at `docs/with-specification.md:4674`

The specification literally requires:

```
fn source(self: &Self) -> Option[&dyn Error]: Some(&self.source)
```

Current diagnostics in embedded `std/result.w:30` reject both:

- `&ParseError -> &dyn Error`
- `&ContextError[ParseError] -> &dyn Error`

Relevant implementation:

- `SemaCheck.w:379-387`,
  `call_arg_type_compatible_base/call_arg_type_compatible`
- ordinary call checking around `SemaCheck.w:13564-13579`
- codegen's existing dyn-argument coercion around
  `CodegenDispatch.w:14269-14282`

The checker special-cases a direct dyn-object expected type, but `&dyn Error`
has outer kind `TY_REF`, so it falls through ordinary compatibility and is
rejected. Codegen already has machinery to build a dyn fat pointer; verify its
reference path rather than merely suppressing the diagnostic.

Exhaust the small coercion matrix in one repro:

- concrete value to `dyn Trait`, if spellable
- `&Concrete -> &dyn Trait`
- mutable/reference variants allowed by the spec
- `Box[Concrete] -> Box[dyn Trait]`
- a concrete type that does not implement the trait must still fail

### 7.3 ScopedMut fixtures still use the old pointer-shaped binding

Tests and spec:

- `test/spec/spec_ss07_with_blocks.w:22-27`
- `test/spec/spec_ss14_17_rwlock_generic.w:54-63`
- §7.1/§7.2 at `docs/with-specification.md:2666` and `:2704`
- §14.17 at `docs/with-specification.md:7390`

These are stale fixtures, not evidence that the compiler should accept the old
shape.

`lib/std/sync.w:182-190` and `:283-291` implement
`ScopedMut[T]`; `with_enter_mut` returns `T`, the body mutates that local
value, and `with_exit_mut` writes it back. Therefore:

- change `*data = *data + 2` to `data = data + 2`
- change `seen = *data` to `seen = data`
- change `*value = *value + 2` to `value = value + 2`

Do not remove the dereference in read-guard cases. `Scoped[&T]` still binds a
reference, so lines such as `*data + 2` and read-side `*value` remain
correct.

### 7.4 Mutex generic fixture needs explicit ownership transfer

Test:

- `test/spec/spec_ss14_17_mutex_generic.w:36`
- `test/spec/spec_ss14_17_mutex_generic.w:47`

`Counter` is non-Copy. `Mutex.new(value: T)` and
`Mutex.set(value: T)` consume/store their value. The fixture must say:

```
Mutex[Counter].new(move initial)
lock.set(move next)
```

The language rule is stated at `docs/with-specification.md:904-912`: a plain
`T` parameter consumes, and `move x` explicitly transfers ownership.

This is test migration, not a reason to weaken the consume/escape check. After
updating it, verify the existing drop trace still produces exactly
`oldnew`; that is the semantic acceptance criterion.

### 7.5 Default trait method calling a required method — runtime abort

Test and spec:

- `test/spec/spec_ss11_6_trait_default_methods.w`
- §11.6 at `docs/with-specification.md:4893`

The harness reports exit 134 only for:

`test_default_trait_method_can_call_required_method`

The failing source is:

```
fn label(self: &Self) -> str:
    self.name() ++ "!"
```

An omitted constant default, an explicit override, and a generic default are
separate tests in the same file. Do not assume they fail.

This failure has not been root-caused to an exact compiler line. Start with the
debug allocator, then LLDB. Relevant paths:

- Sema re-check of default bodies:
  `SemaCheck.w:1876`,
  `check_trait_default_method_body_for_impl`
- default method generation:
  `CodegenTraits.w:484`,
  `generate_default_trait_method_for_impl_ext`
- MIR-based default body generation:
  `CodegenTraits.w:520` and `:684+`
- existing trace: `WITH_DEBUG_DTM=1`

The key question is whether `self.name()` resolves to the Person impl method
with the correct receiver address, or whether synthesized default-method MIR
retains trait/Self identity and calls through the wrong ABI.

### 7.6 Option-pointer null at a call site — lowering bug

Test and spec:

- `test/spec/spec_ss16_10_null_pointer_literal.w`
- §16.10 at `docs/with-specification.md:8976`

Fresh trusted-gen-2 evidence:

```
WITH_DEBUG_ALLOC=1 /tmp/gc-contract6-g2 run \
  test/spec/spec_ss16_10_null_pointer_literal.w
```

Result:

```
panic at test/spec/spec_ss16_10_null_pointer_literal.w:27:5: assertion failed
```

The preceding local assignment works:

```
let optional: Option[*mut i32] = null
assert(optional.is_none())
```

The direct call does not:

```
assert(takes_optional_ptr(null))
```

Strong first-breakpoint candidate:

- Sema records the expected target through
  `SemaCheck.w:5352-5357`.
- `MirLower.expr_type` nevertheless hardcodes a null literal to `i32` at
  `MirLower.w:1949-1950`.
- `MirLower.lower_expr` emits `CK_INT(0, ty_i32)` at
  `MirLower.w:11171-11173`.
- Assignment has a destination type that can repair/coerce the zero. A call
  operand has no such place context, so the Option-pointer ABI receives the
  wrong shape.

Confirm with `--dump-mir`/`--trace-place` and a breakpoint before changing
the representation. The same test already enumerates raw const/mut pointers,
Option pointer, null function pointer, and non-null function pointer; all cases
must remain correct.

### 7.7 C callback context prints bad, without an allocator leak

Test and spec:

- `test/spec/spec_ss16_7_callback_context.w`
- §16.7 at `docs/with-specification.md:8931`
- helpers in `lib/std/ffi.w:37-59`

Fresh trusted-gen-2 evidence:

```
WITH_DEBUG_ALLOC=1 /tmp/gc-contract6-g2 run \
  test/spec/spec_ss16_7_callback_context.w
```

Result:

```
bad
debug-alloc: leak count=0
```

This is not yet root-caused. The test's `ok` flag can be cleared by:

- Drop running during `box_ctx`
- callback results not being 15 and 115
- `ctx_ref` not observing 115
- destroy not making `SS167_DROPS == 1`

Do not add trace prints and rebuild. Compile the test with debug symbols and
use LLDB breakpoints at its existing condition lines (44, 49, 52, 56, 60) to
identify the first false condition. Then break in the exact relevant path:
`box_ctx`, indirect extern-C call marshalling, `ctx_ref`, or `drop_ctx`.
The allocator already rules out a surviving leak; it does not rule out an
early/drop-count or ABI-value bug.

### 7.8 RwLock and Mutex may reveal deeper runtime work after fixture migration

The currently captured RwLock failure is the stale mutable-binding syntax, and
the Mutex failure is missing `move`. Their tests also cover:

- generic aggregate payloads
- replacement/drop order
- contention and fiber yielding
- reader/writer exclusion

After the fixture corrections, run the complete files. A compile pass alone is
not success; their runtime assertions and drop traces must pass. Any allocator
failure begins with `WITH_DEBUG_ALLOC=1`, followed by
`--dump-drop-state`, `--trace-ownership`, `--dump-drop-plan`, and LLDB.

## 8. Recommended next sequence

1. Re-read `AGENTS.md`, this file, and `out/project-state.md`; check
   `git status --short`.
2. Rebuild the committed current-driver graph and run the full inventory:

   ```
   WITH=/tmp/with-impl-kind-bridge /tmp/with-impl-kind-bridge build
   WITH=/tmp/with-impl-kind-bridge /tmp/with-impl-kind-bridge build :fixpoint
   cp out/release/bin/with /tmp/gate10f7771e-driver
   WITH_MEMORY_LIMIT_BYTES=0 WITH=/tmp/gate10f7771e-driver \
     /tmp/gate10f7771e-driver build :test
   ```

   Read the graph's own “N of M files failed” and per-suite summaries. The
   expected spec count is eight, but record facts rather than assuming it.
3. Commit the three fixture-only corrections as their own logical change:
   ScopedMut binding syntax in two files and explicit moves in the Mutex file.
   Run all three files, including their drop/runtime assertions.
4. Fix `&Concrete -> &dyn Trait` and Box nested autoderef as separate compiler
   changes. For each: exact-line proof, focused regression, two generations,
   `audit:all`, then full build/fixpoint.
5. Root-cause the three remaining runtime/dispatch items independently:
   default trait method, Option-pointer null call, callback context.
6. After any receiver/drop/ownership/cancellation change, run:

   ```
   python3 .claude/skills/drop-audit/audit.py --with /tmp/change-g2
   ```

7. Once every suite is green:

   ```
   with build
   with build :fixpoint
   with build :test
   with build :test-green
   with build :last-green
   ```

   Use the converged current compiler, not the deviant bridge, for the final
   evidence chain.
8. Stop and request explicit maintainer authorization before:

   ```
   with build :update-seed
   with build :install-user
   ```

Never reseed from an uncommitted tree or from an intermediate generation.

## 9. Workflow rules that mattered

- Build and fixpoint are mandatory after every compiler/runtime/stdlib or
  generated-source logical change.
- A build is a specific verification question, not an experiment. Prefer
  source inspection, `rg`, `nm`, `otool`, MIR diagnostics, and LLDB before
  paying for a five-minute build.
- Do not edit source while a compiler build is running.
- Never switch to `-O0`; every stage is `-O1`.
- For deep compiler repros, minimize with `with reduce` and use
  `--trace-place`, `--explain-mir-origin`, `--trace-ownership`,
  `--dump-drop-plan`, `--dump-place-map`, `--trace-cleanup-edge`, and
  `--validate-all` before adding temporary traces.
- For memory/drop bugs, begin with the native debug allocator, then use LLDB
  to name the compiler branch that emitted the bad drop.
- Root cause means the exact function, branch, and condition. Output counts or
  malformed LLVM are characterization until a breakpoint/watchpoint proves
  the producer.
- Never add a silent fallback. If correct output cannot be generated, emit a
  diagnostic and exit non-zero.
- Preserve one logical change per commit. Eric Hartford is the sole author;
  never add AI co-author or credit trailers.

## 10. Working-tree and generated-state notes

- `10f7771e` contains all compiler/stdlib edits from this phase.
- `docs/handoff.md` is intentionally modified by this rewrite.
- `out/project-state.md` is ignored scratch state. It still names
  `5cf5eac9` in its HEAD summary and says the contract cluster needs a
  commit; update it at the start of the next phase.
- Generated/ignored files include the embedded stdlib and generated
  `out/gen/main.w`. Regenerate them through build targets, never hand-edit
  generated output.
- No full post-`10f7771e` suite verdict exists.
- No seed or installed compiler was changed.

## 11. Completion criteria

The D7 receiver campaign itself is substantially complete, but the repository
is not done until:

- the remaining spec failures are corrected with runtime semantics verified
- behavior, compile-error, codegen, and spec suites all pass
- `audit:all` and the drop audit pass
- stage 2 and stage 3 are byte-identical
- test-green/last-green evidence is recorded
- the maintainer explicitly approves reseeding
- the converged compiler is used for `:update-seed` and `:install-user`

Do not redefine success as “the files compile.” The runtime assertions, drop
counts, ABI behavior, and spec-prescribed coercions are the success condition.
