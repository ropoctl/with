# Handoff: release-blocker campaign toward stable v0.16.0

Rewritten 2026-07-15 as a self-contained takeover document. Read `AGENTS.md`
first, then this. Supersedes the earlier release-blocker handoff; git history
retains prior versions (`356e7750`, `ffe58231`, `b987f97c`).

---

## 1. Executive status

- Branch: `main`. HEAD: **`058f38c5`** (pushed to origin).
- **8 of 10 silent-wrongness release blockers are FIXED, gated, and pushed.**
  Each landed as its own two-generation-verified, fully-gated commit.
- **One blocker (#643) has an UNCOMMITTED fix in the working tree** — build +
  fixpoint verified, but audit:all / drop-audit / `:test` not yet confirmed
  (the gate run was interrupted). See §5 for the exact state and how to finish.
- Two blockers removed from the set with analysis: #549 (deferred — false-
  positive risk), #644 (re-triaged — D7 already made it loud, not a blocker).

Working tree (uncommitted):
```
 M src/ComptimeEval.w                                  # #643 fix (narrowed)
?? test/behavior/behav_global_read_into_local_tail.w   # #643 fixture
```

### Maintainer intent (Eric, 2026-07-14/15)

Get to a release, but only from a **stable** place. "Stable" is defined
operationally: **the compiler is never silently wrong** — no program that
type-checks green then traps, mutates nothing, mis-parses, or returns a
wrong value. That is the release gate, NOT feature-completeness. Product-
surface gaps (std.net stubs #658, std.time #657, native fetch #623, c_import
macros #582), Windows (#297/#298/#369), and emit-C (#668/#619) are explicitly
**not** blockers; they ship as documented limitations.

Iteration cadence: last release was **v0.15.1 on 2026-06-08**; ~500 commits
since with no release. Eric wants short iterations again — the agreed model is
**one class-kill = one release** after this campaign (see §9).

---

## 2. Release-blocker scoreboard

The 10-issue silent-wrongness set (from the 2026-07-14 investigation workflow),
by cluster. All CLOSED issues are pushed with evidence comments.

| # | Title (abbrev) | Cluster | Status | Commit |
|---|---|---|---|---|
| 653 | early `return <value>` → Unit, undef branch trap | A return-inference | CLOSED | `e7ffc479` |
| 659 | inferred-Unit fn, `return <value>` swallowed | A | CLOSED | `e7ffc479` |
| 652 | trait-impl inferred return rejected vs trait | A | CLOSED | `e7ffc479` |
| 654 | `if unit_call():` never type-checked → runtime trap | B cond/branch | CLOSED | `759667c6` |
| 631 | unit pattern `()` rejected | B | CLOSED | `759667c6` |
| 622 | array-literal→slice binding: silent corruption + segfault | C slice | CLOSED | `edd472de` |
| 663 | variant payload misparse (garbage binding) | D match-payload | CLOSED | `a4419996` |
| 634 | `Some(x)` as operator operand: no codegen dest type | E codegen | CLOSED | `058f38c5` |
| 549 | incompatible `if` branches pass without diagnostic | — | **DEFERRED** | — |
| 644 | `mut self` on primitive/str passes by value | F receiver | **NOT A BLOCKER** | — |
| 643 | global read into local drops tail value | F globals | **FIX UNCOMMITTED** | — |

Backlog: 660 filed lifetime / **~43 open** at HEAD. Of the open set only a
handful are census-class correctness bugs; the rest are product surface, test
tracks, Windows, infra. Full backlog triage (32 issues) from 2026-07-14 lives
in the workflow journal (§8); headline: **zero issues found spec-obsolete**
despite D5/D7/D8.

---

## 3. Fixes landed this session — with source + spec references

Every fix went through: minimal repro → exact-line root cause (dumps/lldb) →
fix → two-generation build (no self-host flip) → `with build` + `:fixpoint`
(stage2==stage3) + `analyze audit:all` (0 violations) + drop-audit (25 cells,
0 fail) + full `:test`. Each carries behavior and/or compile-error fixtures.

### Cluster A — return-type inference (`e7ffc479`) — #653, #659, #652

- **Root cause (#653/#659):** `Sema.check_return` (src/SemaCheck.w ~8785)
  computes the return value's type, but `check_expr` types bool literals
  (src/SemaCheck.w:5368 `NK_BOOL_LIT` returns `ty_bool` with no
  `typed_expr_types.insert`) and binary-operator results without self-
  recording them. Return-type inference (`body_return_type_info`,
  src/SemaCheck.w:4912; fed by `recorded_expr_type_or_zero`, :4781) then read
  the value back as `0` (unrecorded) and `merge_body_return_type_info`
  (:4879-4883) misclassified the value-return as a **bare** `return`,
  finalizing the signature as Unit (`infer_unannotated_function_return_type`,
  :4971). Caller branched on `undef`, trapping at -O1.
- **Fix:** record `val_type` at the single choke point in `check_return`
  (`if val_type != 0: self.typed_expr_types.insert(value, val_type as i32)`).
  Fixes every node kind at once and re-armed the mixed bare/value-return
  diagnostic.
- **#652:** `check_trait_impl_method_signature_contract` (src/SemaCheck.w:1510)
  compared the impl method's return against the trait's **before inference
  ran**, so an unannotated method saw the placeholder `ty_void`. Now guarded
  on `has_ret_annotation` (computed at :1588, passed through).
- **Spec:** §29.13 / §4.9–§4.10 (last expression is the function's value);
  §15.2 conformance.
- **Flip risk (#629):** signature-fact diff over compiler sources showed 0
  changed inferred returns; build clean.

### Cluster B — condition & branch checks (`759667c6`) — #654, #631

- **#654:** if/while/do-while conditions had their type computed and
  discarded. Added `Sema.check_bool_condition(cond, what)` (src/SemaCheck.w,
  just before `check_if_expr`) — requires bool, accepts a diverging `Never`
  or already-errored condition — and routed the three sites through it
  (`check_if_expr` ~8221; while ~5493; do-while ~5544).
- **Flip work-queue (the #629 red build IS the queue):** the check surfaced 6
  compiler-internal sites branching directly on an i32-returning predicate
  (`types_compatible`/`types_compatible_frozen`/`has_drop_method` in Sema.w;
  a `types_compatible` in SemaCheck.w:8289; `is_bitpacked` in Codegen.w:3522;
  `c_import_is_int_literal` in Frontend.w:1019). Each made explicit with
  `!= 0` — the codebase's dominant idiom. **This is "fix the code to pass the
  check," not weakening the check.**
- **#631:** the unit pattern `()` is typed `ty_void`, not a zero-element
  tuple, so it failed `check_pattern`'s `NK_PAT_TUPLE` arm (src/SemaCheck.w
  ~11883). Accept it when `type_is_unit(resolved)`; **and in the two MIR
  lowerings** (src/MirLower.w ~7317 match: irrefutable goto arm; ~7542
  binding: no bindings). The behavior fixture caught that the Sema-only fix
  was insufficient.
- **Spec:** §13 control flow (bool conditions); §10 pattern matching.

### Cluster C — array-literal→slice binding (`edd472de`) — #622

- **The original report and the batch investigation were WRONG** (both
  implicated the `[T]` surface syntax and proposed a parser rejection).
  Disproven by running the compiler: the proper `[]i32` spelling corrupts
  identically (`let a: []i32 = [1,2,3,4]` → `a.len() == 2`; `[10,20,30]` →
  `len == 20`; **it reads element[1]** — the array literal is bit-
  reinterpreted as a slice header `{ptr,len}`; indexing segfaults rc=139).
  Rejecting `[T]` would also break the stdlib (lib/std/iter.w:50,54 use `[T]`
  **parameters**, which work).
- **Root cause:** `check_array_literal` (src/SemaCheck.w) returns the
  *expected slice type* for an array literal when the expected type is a
  slice, so the let-binding sees matching types (SemaCheck.w:8143) while MIR
  lowers an array **value** — type and value disagree.
- **Fix:** binding a slice to an array **literal** is fundamentally unsafe
  (the temporary array is freed at end of statement → dangling slice; the
  call-argument path rejects the same temporary at SemaCheck.w:422). The
  named-array form is already rejected as a plain "type mismatch in binding";
  this makes the literal form reject **loudly and consistently** (added just
  before the `val_type` computation in the let-decl checker, SemaCheck.w
  ~8132). Removes the silent corruption + OOB read.
- **Spec:** §3.x sequence types — `[]T` slice (L2258), `[T; N]` array
  (L1658); `[T]` is not valid type syntax.
- **Follow-up (not a blocker):** proper array-literal→slice binding via
  temporary lifetime extension (Rust-style rvalue promotion). Documented on
  the closed issue.

### Cluster D — variant-payload misparse (`a4419996`) — #663

- **Root cause:** `ResolveState.bind_pattern` (src/Resolve.w:899-911)
  probed the variant-payload slot with a numeric kind-RANGE (`>= NK_PAT_WILDCARD
  (100) and <= NK_PAT_SLICE (113)`) that **excluded** NK_PAT_TYPED_BIND (114) /
  REGEX (121) / REST (125) and **included** the non-pattern NK_MATCH_ARM (110).
  So `V(x: T)` fell to the else branch and registered a `DK_LOCAL` keyed on a
  pattern NODE id (garbage) — the surviving sibling of #660's untagged union.
- **Fix (part 1):** replace the probe with the authoritative
  `AstPool.is_pattern_node` (src/Ast.w:1616 → `ast_is_pattern_kind` :1597,
  which explicitly enumerates all pattern kinds and excludes MATCH_ARM),
  delete the dead sym-guessing branch (every producer stores nodes), and add
  the missing `NK_PAT_TYPED_BIND` binder to `bind_pattern`.
- **Fix (part 2):** fixing the resolver EXPOSED a latent segfault — a typed-
  bind pattern `name: Type` is a **dynamic trait-object downcast** whose MIR
  handler (src/MirLower.w:7360) emits `DYN_VTABLE_CMP`; on a concrete subject
  (i32 payload) it ran with a null trait and crashed. Sema now rejects
  typed-bind on a non-trait-object subject (src/SemaCheck.w ~11733, guard on
  `get_type_kind(resolve_alias(subject_type)) != TypeKind.TY_TRAIT_OBJ`). The
  dyn-downcast use (test/behavior/sealed_trait_match.w, `s: dyn Shape`) is
  unaffected.
- **Note:** #663 lists 5 readers of this slot; only Resolve.w was the live
  misparse. The others (render.w, SemaCheck.w:11769, ComptimeEval.w:6107) are
  dead-but-harmless (all producers store nodes) — sweep under #651 if desired.

### Cluster E — enum-variant constructor as operand (`058f38c5`) — #634

- **Root cause:** `lower_bin_op` (src/MirLower.w:3763) lowered a comparison's
  operand with the ambient `expected_type` (bool for `if a == b:`), and the
  variant-constructor arm (src/MirLower.w:11605-11614,
  `if self.expected_type != 0: vc_result_ty = self.expected_type`) used that
  as the aggregate's type instead of Option[i32] → "aggregate rvalue missing
  destination struct type".
- **Fix:** for EQ/NEQ/LT/GT/LTE/GTE, lower each operand with the **other**
  operand's type as `expected_type` (src/MirLower.w:3810-3821) — generalizing
  the per-operand rebind #586 established for the bare-`None` case. Plain
  scalar comparisons unaffected.

---

## 4. Deferred / re-triaged (with analysis)

### #549 — incompatible `if` branches pass without diagnostic (DEFERRED)

Confirmed and root-caused (`check_if_expr`, src/SemaCheck.w ~8277: incompatible
branches yield `result_type == 0`, the error type, silently absorbed). The
naive fix (error when `arithmetic_result_type == 0 && in_value_context`)
**false-positives** on the compiler's pervasive `BlockId`-vs-`i32` mixing:
`BlockId = distinct i32` (src/Mir.w:10), but block ids are passed as raw `i32`
(`fail_bb: i32`, `arm_bb: i32`) while `new_block()` returns `BlockId`, so
`if c: new_block() else: 0` / `else: fail_bb` mix distinct-over-same-base. A
correct check needs distinct-base-aware incompatibility (`numeric_operand_type`
/ `is_numeric_type` at Sema.w:3393/3407 do NOT unwrap distinct; there is no
`TY_DISTINCT` kind / base accessor). Entangled with #651. Full writeup posted
on the issue. Not a blocker on its own (needs an incompatible-literal branch
assigned to an annotated binding — narrower than #654, which is fixed).

### #644 — `mut self` on primitive/str (NOT A BLOCKER)

The silent bug (mutation lost) **no longer reproduces** — D7 receiver-mode
enforcement (landed after the issue was filed) already makes every mutation
form (`self =`, `self +=`, nested `mut fn`) a loud compile error ("cannot
assign to immutable variable"). Zero `mut fn` methods on primitive/str owners
exist in the codebase (no flip either way). The stability bar is met. The
remaining A-vs-B ruling (A: lower primitive receivers by pointer / share-place
per §9.5 — an ABI change to `fn_param_uses_value_ref_abi`, SemaDecl.w:1086,
weigh vs docs/completed/mutability.md + decisions.md D5/D6/D7; B: keep
rejecting but with a clearer message) is a post-release maintainer decision.
Full writeup on the issue.

---

## 5. #643 — IN PROGRESS (finish this first)

**Issue:** reading a plain top-level global (`var`/`let`, no `global` keyword)
into an unannotated local drops the function's implicit tail value — returns
the type default instead. Spec §29.13/§4.9-4.10.

**Root cause (nailed, exact line):** the parser gives a **plain** top-level
`let`/`var` `global_bits = 0` (src/Parser.w:2693-2695 — only the `global`
keyword sets `LET_FLAG_GLOBAL`/`LET_FLAG_GLOBAL_VAR`). So `let_decl_is_global`
(src/Ast.w:333, `(flags/4)%2`) is 0, and `check_top_level_let_values`
(src/ComptimeEval.w:7031, called from `check_module` Sema.w:5494 **before**
`check_bodies` :5496) **skipped** the decl (old line 7046). Its type was never
inferred — it kept the `0` that `collect_let_decl` → `register_top_level_global_decl`
(src/SemaDecl.w:1931 / Sema.w:3859) registered (bind_ty from annotation only,
`0` when unannotated). Reading it into an unannotated local propagated the
unresolved type (`bind mid: <error>`, MIR local `ty14`), and the tail failed
the tail-as-return type check → `_0 = const ()`. Proof: MIR diff showed the
tail computed into `_3` but `_0 = const ()`; `print_i32(mid)` showed the VALUE
was correct (7) — only the declared TYPE was wrong. Annotating either the
global or the local fixes it (both give a concrete type).

**Fix (implemented, UNCOMMITTED, src/ComptimeEval.w:7046):** infer the type of
a plain top-level let too — but **only while its scope type is still 0**:
```
if is_comptime_value == 0 and let_decl_is_global(flags) == 0 and self.scope_lookup(name) != 0:
    continue
```
The `scope_lookup(name) != 0` guard is load-bearing: a first, broader version
(process ALL plain top-level lets) **regressed migrated c_import codegen**
(`lib/std/re/pcre2_substitute.w` etc. — "IR generation failed" on
`__ci_expr_logic_*`). The narrowed guard leaves already-typed globals
(annotated user decls + typed migrated globals) undisturbed and only fills in
genuinely-unresolved plain lets. **Lesson: the `src/main.w`-only two-gen build
did NOT catch this — only the full `with build` (which codegens lib/std/re/)
did. Always run the full build before trusting a Sema change.**

**Verified so far:** `/tmp/t643.w` (var), `t643b.w` (let), `t643c.w`
(explicit return) all print 12; two-generation build clean; **full `with build`
+ `:fixpoint` GREEN**.

**NOT yet confirmed (the gate run was interrupted):** `analyze src/main.w
audit:all`, drop-audit, full `:test`. Fixture written:
`test/behavior/behav_global_read_into_local_tail.w`.

**To finish #643:**
1. `WITH=/tmp/seed-conv ./out/release/bin/with analyze src/main.w audit:all`
   (expect `violations=0`).
2. `python3 .claude/skills/drop-audit/audit.py --with out/release/bin/with`
   (expect `0 fail`).
3. `WITH=/tmp/seed-conv WITH_MEMORY_LIMIT_BYTES=0 ./out/release/bin/with build :test`
   (behavior count should be +1; expect `test rc=0`). Grep the harness's own
   `ok:` / `error:` lines — never tail-truncate.
4. Commit `src/ComptimeEval.w` + the fixture; push; `gh issue close 643` with
   an evidence comment noting the migrated-code narrowing.
5. Then record the evidence chain (§7) and re-triage whether #640 (same family
   — labeled-statement tail drop) shares this mechanism.

---

## 6. Build / seed mechanics (READ — the seed situation changed)

- **`/tmp/with-impl-kind-bridge` is GONE** (cleaned from /tmp). It was the
  deviant bridge seed. Do not rely on it.
- **`/tmp/seed-conv` = a copy of `out/release/bin/with`** at the time of
  writing — the **fixpoint-converged** binary from the last green gate. It is
  NOT deviant (stage2==stage3), so it is a trustworthy seed. If it is also
  cleaned from /tmp, re-copy from `out/release/bin/with` (which is always the
  latest built release binary). Set `WITH=/tmp/seed-conv` (or
  `WITH=./out/release/bin/with`) for `with build`.
- Because the seed is converged, a single-generation build is already
  trustworthy for Sema-only changes — but keep the two-generation habit
  (`seed → g1 → g2`, trust g2) for ABI/codegen/parser changes.
- **Gate invocation still needs BOTH pieces:** the fresh **release binary as
  the driver** (the installed `~/.local/bin/with` v0.15.1 seed can no longer
  parse HEAD sources — it chokes at src/main.w:56, and its comptime cannot
  evaluate `str.split` for `test-green`), and `WITH=<converged seed>` for the
  seed-consuming bootstrap targets:
  ```
  WITH=/tmp/seed-conv WITH_MEMORY_LIMIT_BYTES=0 ./out/release/bin/with build :test
  ```
- **Never pipe gate commands** (exit-code masking). Redirect to a log, grep
  the `ok:`/`error:` verdict lines.
- The installed seed `~/.local/bin/with` (v0.15.1) is badly stale. **Reseed
  (`with build :update-seed` + `:install-user`) is due** after the campaign
  lands — do it from the CONVERGED build, with maintainer approval per
  AGENTS.md bootstrap rules.
- All `-O1`, never `-O0` (AGENTS.md invariant).

---

## 7. Evidence chain to record after #643 lands

Per AGENTS.md bootstrap sequence, as ONE chain:
```
WITH=/tmp/seed-conv WITH_MEMORY_LIMIT_BYTES=0 ./out/release/bin/with build :test
./out/release/bin/with build :test-green
./out/release/bin/with build :last-green
# then, with maintainer approval, the reseed:
./out/release/bin/with build :update-seed
./out/release/bin/with build :install-user
```
Confirm `GATES EXIT: 0` as its own step before chaining the close/commit.

---

## 8. Investigation artifacts (session-local — may be gone)

Two background workflows ran the 2026-07-14 investigation. Journals persist on
disk under the session subagents dir but are session-scoped:
- `release-blocker-investigation` — run `wf_23d064fb-a9b`. Per-issue repro +
  root cause + fix + fixtures + risk. NOTE: its proposed fixes for **#622 and
  #644 were WRONG** (disproven by running the compiler — see §3/§4); trust the
  landed commits, not the workflow's fix directions.
- `backlog-spec-relevance-triage` — run `wf_5a2e175e-abe`. 32/35 open issues
  re-validated vs current spec + decisions.md. STALE-NEEDS-UPDATE (12, rewrite
  premise): #357 #491 #501 #507 #558 #561 #571 #582 #604 #615 #624 #649.
  ALREADY-FIXED candidates (verify then close): #578 (raylib c_import builds on
  current compiler), #593 (requirements Python script deleted 5cb48c36). NOT
  TRIAGED (agent hit usage limit): #297 #298 #489.

Repros live under `scratchpad/blockers/issue-<N>/` and `/tmp/t6*.w` (the /tmp
ones may be cleaned).

---

## 9. Path forward (agreed with maintainer)

1. **Finish #643** (§5), record evidence (§7).
2. **Backlog cleanup** (task list #24): verify + close #578, #593, #646;
   rewrite the 12 stale issues from the journal's `recommended_action`;
   investigate #643's sibling #640; finish triage of #297/#298/#489.
3. **v0.16.0 release** (docs/with-release-runbook.md) + reseed. Headline: the
   D7 receiver model, the audit/tooling suite, the fingerprint-keyed test
   cache, this session's 8+ correctness fixes.
4. **"One class-kill = one release"** going forward: #666 distinct ids (file
   ids first — would have made #667 a compile error), #651 cathedral sweep
   (unify duplicated per-path logic; e.g. the BlockId/i32 inconsistency that
   blocks #549; the 5-reader payload slot from #663), a "every non-generic
   NK_FN_DECL has a MIR body" audit invariant, #650 gate-cycle speedup.
5. **Then** the product surface for the Sep-2026 flagships (Smallhold/Crux/
   Weld): std.net (#658), std.time (#657), fetch (#623), c_import macros
   (#582) — chosen by what the flagships actually consume.

### Discipline that worked this session (keep it)

- **Fix the class, not the instance.** Cluster A recorded the return type at
  one choke point, fixing all node kinds. Cluster B's condition check found 8
  latent sites — fixed the code, never weakened the check.
- **Run it, don't reason it.** #622 and #644's filed/investigated root causes
  were both wrong; running the compiler settled the facts.
- **The full build is the flip detector**, not `check src/main.w` — #643's
  migrated-code regression only showed under `with build`.
- **A fixture that fails is the fix incomplete** — #631 (MIR layer) and #663
  (segfault) were both caught by their fixtures, not by reasoning.
- Every fix: two-generation build + full gate + fixture, one commit, evidence
  comment on the issue.
