# Handoff: release-blocker campaign toward stable v0.16.0

Rewritten 2026-07-14 as a self-contained takeover document. Read
`AGENTS.md` first. This supersedes the spec-suite-debt handoff; git history
retains that version at `b987f97c`.

## 1. Executive status

- Branch: `main`. HEAD: `c14a2e62` (pushed to origin).
- Working tree clean except this file.
- All gates green at HEAD and evidence recorded 2026-07-14:
  full graph build, `:fixpoint` (twice), `:test` (RC=0, includes the new
  invariance-check and comptime-diff targets), `:test-green`, `:last-green`,
  drop-audit (25 cells, 0 fail), `analyze src/main.w audit:all`
  (2,171,934 facts, 0 violations).
- **Maintainer intent (Eric, 2026-07-14): get to a release, but only from a
  stable place.** Stable = the compiler is never silently wrong. The release
  is v0.16.0; the gate is the silent-wrongness blocker list in §3 (now 10
  confirmed + #643 pending, after investigation removed #646/#630).
  Product-surface gaps (std.net stubs #658, std.time #657, fetch #623,
  c_import #582), Windows (#297/#298/#369), and emit-C (#668/#619) are
  explicitly NOT release blockers — they ship as known limitations.
- Iteration context: last release v0.15.1 (2026-06-08); ~500 commits since.
  The maintainer wants short iterations again: after this blocker campaign,
  one class-kill = one release.

## 2. What landed this session (b987f97c..c14a2e62)

Six leverage tools + fixes, all gated and pushed:

1. `invariance-check` (build.w Action, dep of `tests`): five seeded
   meaning-preserving perturbations of the tree must not change the
   compiler's verdict.
2. `analyze ... audit:pool` (Analysis.w, in `audit:all`): parallel-family
   integrity — SoA columns, stride tables, map/vec mirrors, bind_* 9-vec
   parity, decl_source seam.
3. Per-node file-id column in AstPool + `AstFileId` distinct-type pilot
   (campaign: #666).
4. #661 fixed: resolve-phase parse errors render against their own module
   (acceptance: injected parse error in SemaCheck.w renders
   `--> src/SemaCheck.w:<line>`, not phantom `src/main.w:4495`).
5. `test/comptime_diff/` corpus (6 files, comptime==runtime differential);
   known divergences tracked in #665.
6. `--survey` keep-going mode for graph test/action targets
   (DriverOptions.w, main.w; inventoried as implementation-internal).

Also fixed: #664 (bind_* 9th-member environment swap). Closed with
evidence: #655, #661, #664, #667.

### #667 — read this before touching file ids or the text registry

The flaky "missing MIR body for build_graph_resolve_project_path" was
caused by an earlier draft of the #661 fix registering RESOLVE-generation
file ids into the shared Zcu/Sema source-text registry, where they collide
with MERGE-generation ids (two independent i32 id domains, first-match
scan). Wrong text for a fid made `extract_decl_name_after` return
"BTreeMap.new" for a plain fn; the dot-scan in `fn_node_is_generic_template`
(Sema.w ~5341) classified it generic; `lower_module` silently skipped its
body; codegen dispatch (a DIFFERENT genericity predicate) then failed.
The fix confines registration to the resolve-error early-out
(Frontend.w `register_resolved_source_texts`). Full narrative on #667.
Standing hazards folded into #666/#651: text-probing genericity predicate;
lower_module vs dispatch predicate divergence; multi-writer i32 registry.
Never re-introduce unconditional resolve-id registration.

## 3. The release-blocker list — investigated 2026-07-14

Two background workflows ran the investigation + backlog triage
(§4 has provenance/caveats). Root causes below are single-agent findings
with exact file:line; the adversarial verifier pass did NOT complete for
most (usage limit) — treat each as a strong lead, and let the per-cluster
gate + the fixer's own re-read be the verification. All reproduce on the
current release compiler unless noted.

### 3a. Removed from the blocker set

- **#646 — CLOSE (already fixed).** Does NOT reproduce; dissolved by D7
  (commit a27c9e3e; decisions.md D7 lists it). Only gap is coverage: add a
  compile-error fixture `fn Type.name(self: ConcreteType)` and close.
- **#630 — DOWNGRADE (not silent-wrong).** `vec.len() - 1` on empty Vec is
  a CORRECT loud unsigned-underflow trap; the defect is only the panic
  message lacking file:line (CodegenDispatch.w:2191 → emit_runtime_panic
  hardcodes empty file/line). Diagnostic-quality, not a stability blocker.
  Fix when convenient (thread `current_stmt_span` into emit_runtime_panic).

### 3b. True silent-wrongness blockers (10 + #643 pending)

Clustered by shared root / touched phase — one CLUSTER = one gated
bootstrap cycle = one commit series:

- **Cluster A — return-type inference (Sema).** #653 and #659 are the SAME
  root: `merge_body_return_type_info` (SemaCheck.w:4881-4883) conflates
  "type not recorded" (actual==0) with a bare `return`, because
  `typed_expr_types` is never populated for bool-literals or binary-op
  results — so an unannotated fn with `return <bool/comparison/arith>`
  silently finalizes Unit, caller branches on undef, traps at -O1. Fix:
  record `val_type` in `check_return` (SemaCheck.w:8785), one choke point;
  add a loud "cannot infer return type" guard in the merge. #652 is the
  same family, different site: trait-impl contract (SemaCheck.w:1523)
  compares against the placeholder ty_void for unannotated methods — skip
  the comparison when there's no return annotation.
  **⚠ Self-host flip risk (#629): the fix changes the finalized signature
  of any compiler/stdlib fn that currently mis-finalizes Unit; expect a
  possible flag-day red build whose error list IS the work queue. Diff
  `analyze` signature facts over compiler sources before/after.**
- **Cluster B — condition/branch type-check gaps (Sema).** #654: `if`/
  `while`/`do-while`/`match` never verify the condition is bool
  (SemaCheck.w:8215 etc.) — `if unit_call():` checks ok, traps at runtime
  (this is the companion trap to Cluster A). #549: incompatible `if`
  branches (str vs i32) silently fall through `arithmetic_result_type`
  with no error (SemaCheck.w:8271). #631: empty-tuple pattern `()` rejected
  because `()` is typed ty_void not zero-elem TY_TUPLE (SemaCheck.w:11857).
  All three live in the check_if_expr / check_pattern region; fixes are a
  `check_bool_condition` helper + poison-convention error + `type_is_unit`
  accept branches.
- **Cluster C — slice annotation (Parser).** #622: `[T]` parses AST-
  identical to `[]T` (Parser.w:7482), producing a silently corrupt slice
  (wrong `.len()`). Fix: reject `[T]` at parse with a "write `[T; N]` or
  `[]T`" diagnostic.
- **Cluster D — match payload misparse (Resolve).** #663: `bind_pattern`
  payload probe is a numeric kind-RANGE (Resolve.w:906) that excludes
  NK_PAT_TYPED_BIND/REGEX/REST and includes non-pattern kinds — the exact
  #660 untagged-union family. Fix: node-only slot + `is_pattern_node`,
  delete the sym-guessing branch.
- **Cluster E — codegen hole (MirLower).** #634: ambient `expected_type`
  overrides Sema's recorded node type for a variant-constructor used as an
  operator operand (MirLower.w:11605), so `Some(x)` as an operand gets the
  wrong aggregate type. Fix: rebind expected_type per operand (the #586
  pattern).
- **Cluster F — receiver mode (Sema/ABI), design-adjacent.** #644: mut-self
  on a primitive/str owner passes self BY VALUE, so in-place mutation never
  reaches the caller (SemaDecl.w:1089-1094 early-outs before reading the
  receiver mode). Fix per §9.5 / D5 is share-place for these receivers —
  confirm the ABI direction against `--dump-abi` before touching
  `fn_param_uses_value_ref_abi`.
- **#643 — NOT YET INVESTIGATED** (agent hit the usage limit). Re-run its
  investigation (resume the workflow, or by hand) before finalizing the
  set. Filed as: reading a top-level global into a local drops the fn's
  implicit tail-expression value (#640 family) — likely Cluster A/E-adjacent.

Repros for the investigated issues are under
`scratchpad/blockers/issue-<N>/`. Full per-issue root cause + fix + fixture
plan is in the workflow journal (§4).

## 4. Workflow results + provenance (2026-07-14)

Both workflows COMPLETED (tail agents errored on the Fable 5 usage limit;
the session then switched to Opus 4.8). Results are session-local; the
journals persist on disk:

1. `release-blocker-investigation` — run `wf_23d064fb-a9b`. Journal:
   `~/.claude/projects/-Users-eric-with/ef176777-c53d-45c1-b06c-b9dae2391f27/subagents/workflows/wf_23d064fb-a9b/journal.jsonl`
   (one `{"type":"result"}` line per agent, full root_cause/proposed_fix/
   fixtures/risk). 12/13 investigated (#643 missing); adversarial
   verifiers mostly did NOT run → root causes are UNVERIFIED single-agent.
   Script: `.../workflows/scripts/release-blocker-investigation-wf_23d064fb-a9b.js`
2. `backlog-spec-relevance-triage` — run `wf_5a2e175e-abe`. Journal:
   `.../subagents/workflows/wf_5a2e175e-abe/journal.jsonl`.
   32/35 triaged (#297, #298, #489 hit the limit). **Headline: ZERO issues
   found spec-obsolete** despite D5/D7/D8 — the backlog is real, not ghosts.
   - STILL-VALID (18): #369 #490 #502 #570 #583 #591 #616 #618 #619 #623
     #637 #638 #650 #651 #656 #657 #658 #662.
   - STALE-NEEDS-UPDATE (12, rewrite premise/section refs, keep open):
     #357 #491 #501 #507 #558 #561 #571 #582 #604 #615 #624 #649. Corrected
     text is in each journal row's `recommended_action`.
   - ALREADY-FIXED candidates (2, close pending — verifier never ran, so
     UNVERIFIED): #578 (raylib c_import builds on current compiler; fixed
     since v0.14.8) and #593 (requirements Python script deleted in
     5cb48c36; matrix retired). Re-verify each, then close with the drafted
     comment.
   - NOT TRIAGED (3): #297 #298 #489 — resume before declaring the sweep
     complete.

Next actions, in order: (a) verify + close #578, #593, #646 [+#655/#661/
#664/#667 already closed]; (b) rewrite the 12 stale issues; (c) investigate
#643 and finish triage of #297/#298/#489; (d) land blocker clusters A–F
through gates (Cluster A first — it's the biggest self-host-flip risk and
unblocks the runtime-trap family); (e) `docs/with-release-runbook.md` for
v0.16.0 + reseed.

## 5. Build/gate mechanics (hard-won this session)

- Current good binaries: `out/release/bin/with` == `/tmp/tools6e-g2`
  (generation-2, fully gated, built from HEAD). `/tmp/tools6e-g1` is its
  generation 1. `/tmp/with-impl-kind-bridge` remains the deviant bridge
  seed: fine as a SEED, never trust generation-1 behavior — two-generation
  discipline stands.
- **Gate invocation needs BOTH env pieces** (this cost hours):
  `WITH=/tmp/with-impl-kind-bridge WITH_MEMORY_LIMIT_BYTES=0
  ./out/release/bin/with build :test`
  — the current release binary must be the DRIVER (the installed seed's
  comptime can't evaluate `str.split`, which `test-green` needs), and
  WITH= must point at the bridge (seed-consuming bootstrap targets must
  compile current sources).
- **The installed seed `~/.local/bin/with` (v0.15.1) can no longer parse
  HEAD sources** (chokes at src/main.w:56). Symptom if you use it: a wall
  of phantom "expected declaration" errors rendered against
  out/gen/main.w. Reseed (`:update-seed` + `:install-user`) after the next
  green milestone — maintainer approval per AGENTS.md.
- Never pipe gate commands (exit-code masking); redirect to a log file and
  grep the harness's own verdict lines.
- Full-compiler `--emit-c` is broken pre-existing (#668, plus OOM #619);
  the in-gate emit-C smoke passes. Do not chase it as a regression.

## 6. Debugging protocol reminders (from the #667 hunt)

- lldb over instrument-rebuild loops. With-binary specifics: line tables
  all map to main.w:4495 → use `br set -n 'Type.method'` and
  symbol+offset address breakpoints from `disassemble -n`; str args are
  (ptr,len) register pairs (`memory read -s1 -fc -c<len>`); `mov w0, wN`
  before a `bl` is an argument move, not a return site; `finish` from a
  breakpoint in an INLINED frame lies about the return value.
- lldb disables ASLR by default — layout-dependent bugs can vanish under
  it; `settings set target.env-vars X=1` to reproduce env-sensitive state.
- Memory files: `feedback_lldb_over_instrumentation.md`,
  `project_667_fileid_domain_collision.md`.

## 7. After the blockers: the agreed path

1. v0.16.0 release (runbook) + reseed — headline: D7 receiver model,
   audit/tooling suite, five weeks of fixes.
2. Horizon "class-kill per release": #666 distinct ids (file ids first),
   #651 cathedral sweep, missing-body audit invariant, #650 gate-cycle
   speed. One class = one short iteration = one release.
3. Then the product surface for the Sep 2026 flagships (Smallhold/Crux/
   Weld): std.net, std.time, fetch, c_import — chosen by what the
   flagships actually consume.
