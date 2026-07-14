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
  is v0.16.0; the gate is the 13-issue blocker list in §3. Product-surface
  gaps (std.net stubs #658, std.time #657, fetch #623, c_import #582/#578),
  Windows (#297/#298/#369), and emit-C (#668/#619) are explicitly NOT
  release blockers — they ship as known limitations.
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

## 3. The release-blocker list (13)

Silent-wrongness bugs gating v0.16.0, by expected cluster:

- return-type/check gaps: #653, #659, #652, #549, #654
- silent data corruption: #622, #643
- lost mutation (D7 enforcement): #644, #646
- misparse: #663
- codegen holes: #634, #631
- runtime trap: #630

Fix discipline: one CLUSTER = one gated bootstrap cycle = one commit
series; sweep each landed cluster for self-host flips (#629 protocol);
no point-fixes when the cluster shares a root.

## 4. In-flight work (two background workflows)

Both launched 2026-07-14 from this session; results are session-local —
if this session is gone, re-run from the saved scripts (or redo by hand):

1. `release-blocker-investigation` — run `wf_23d064fb-a9b`, script:
   `~/.claude/projects/-Users-eric-with/ef176777-c53d-45c1-b06c-b9dae2391f27/workflows/scripts/release-blocker-investigation-wf_23d064fb-a9b.js`
   One agent per blocker: minimal repro (scratchpad/blockers/issue-N/),
   re-reproduce on current compiler, root cause to exact file:line, fix +
   fixture plan; adversarial verifier per finding.
2. `backlog-spec-relevance-triage` — run `wf_5a2e175e-abe`, script:
   `.../backlog-spec-relevance-triage-wf_5a2e175e-abe.js`
   Every other open issue re-validated against the CURRENT spec +
   docs/decisions.md + compiler (maintainer flagged deep spec changes since
   filing: D5 share-place, D7 receiver keywords, D8, mutability redesign).
   Verdicts: STILL-VALID / STALE-NEEDS-UPDATE / OBSOLETE-SPEC-CHANGED /
   ALREADY-FIXED; every close recommendation must survive an independent
   adversarial refuter. Judgment rule encoded: the spec LEADS the compiler —
   "not implemented" is never grounds to close.

On completion: close confirmed-obsolete/fixed issues with the drafted
comments, rewrite stale ones, then land blocker clusters (§3) through
gates, then run `docs/with-release-runbook.md` for v0.16.0 + reseed.

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
