# Handoff: current state

Updated 2026-07-18 (late). HEAD = **57970cd7** on `main` + this doc commit.
The battery-first directive for e6c770b9 is COMPLETE — see "GATED" section
below. The prior #489 collection-await campaign is long closed. This handoff
covers a session that drained most of the pre-v0.16.0 bug queue and,
critically, **canonized two BDFL rulings (D11, D12) into the spec/decision-log
that are NOT YET IMPLEMENTED** — those are the primary pending work.

The single most important rule for the incoming agent:

> **"Canonize to law" means write it to the spec + decision log + agent-guidance
> (memory, and CLAUDE.md/AGENTS.md if warranted). It does NOT mean implement.**
> Implementation is a separate, maintainer-greenlit cycle. Two rulings (D11,
> D12) are canonized but unimplemented; the spec deliberately leads the
> compiler. **Never revert the spec to match the compiler** — the compiler is
> what changes. See `decisions.md` D11/D12 and the memory
> `project_active_spec_ahead_deltas`.

---

## Active work — the two canonized-but-unimplemented rulings

### D11 — IMPLEMENTED 2026-07-19 (a80c38c0, battery-green, reseeded ga80c38c0c)

`len()` → `Int` (i64) landed exactly per the map below: the seven sema
sites flipped (len/count/capacity → i64, position → Option[i64]);
size/align stayed usize; compiler sources and lib/std needed ZERO changes
(dual-compatible — the field-form `.len` was already i64). Fixtures:
behav_len_signed.w (new), underflow panic re-pinned via pure u64, spec
18.6 + two §10.3 tests updated to the Int surface. #630 CLOSED. The
section below is the original implementation map, kept for provenance.

### D11 (original map) — `len()` is signed `Int` (i64), never `usize`, never `Option`  →  issue #630

**Ruling (decisions.md D11, canonized in ad6912c3):** `.len()` on every
collection returns `Int` (i64). Never wrapped in `Option` (a held container
always has a length; ownership + init rules make null/uninitialized containers
unrepresentable in safe code, so an Option wrapper would force `.unwrap()` for a
case the compiler already proved impossible). C's `-1`/`size_t` conventions are
translated at the modeled-C binding layer (the `with_net` `-errno` precedent),
never inherited by core types.

**Spec:** §18.6 (`docs/with-specification.md`, ~line 10355) already amended to
`Int`, with an inline "do not revert to usize" note; the SlotMap method-table
`len` row (~line 2633) and the escape-example comment (~line 3121) updated.

**Implementation (NOT done — this is the work):**
- `src/SemaCheck.w`: `collection_len_method_return_type` (~line 16649) returns
  `self.ty_usize` for `len` → change to `ty_i64`. Grep `ty_usize` in
  `src/SemaCheck.w`/`src/Sema.w` for the full site list. Same-class sites to
  flip for a consistent surface: iterator `count` (~16875, ~18794) → i64;
  `position` (~16869, ~18788) → `Option[i64]`; StringBuilder `capacity`
  (~16918, ~18577) → i64.
- **`size`/`align` type-layout methods STAY `usize`** (SemaCheck ~19347) —
  memory-layout constants for FFI, a deliberately-excluded different category.
- Field paths (`s.len` on str/slice/array, SemaCheck 9587/9607/9921) **already
  return `ty_i64`** — the surface was half-signed already; the ruling unifies it.
- `lib/std/collections.w`: BTreeMap/BTreeSet already declare `len() -> i64`
  (was a §18.6 violation, now conformant — leave as-is).
- The runtime already stores lengths as i64 (`with_vec.len`, `with_hashmap_len`).
- **Self-host flip sweep (#629 protocol):** length typing threads through the
  compiler's own sources. After the sema flip, instrument both decisions, diff
  the tree, and **reseed** — the pre-fix seed miscompiles the fixed shape
  (symptom: release works, stage1 breaks) until `with build :update-seed`. See
  memory `project_629_selfhost_flips`.
- **Fixtures:** new `behav_len_signed.w` pinning `v.len() - 1 == -1` on empty,
  the countdown idiom, BTree/builtin agreement. Rework
  `test/behavior/behav_unsigned_underflow_panic_message.w` — it currently pins
  the overflow panic *via* `v.len() - 1`, which STOPS trapping once len is
  signed; re-express it as a pure-`u64` underflow so the message stays pinned.
  Update `test/spec/spec_ss18_6_collection_length_methods.w`.

The panic-message fix (f0c627ca) already landed on #630 and named the trap
(`integer overflow: u64 subtraction wrapped below zero`); D11 removes the trap
itself.

### D12 — SCALAR TIER IMPLEMENTED 2026-07-19 (566bc58b, battery-green, reseeded g566bc58ba)

#677 CLOSED: scalar/distinct-over-scalar `mut fn` receivers lower via
share-place (single D6 classifier; `--dump-abi` verdicts D12-aware);
bare-self assignment legal for drop-free owners; `let` scalar receiver
gets the spec's clean error. Two foundation bugs found and filed in the
process: **#689** place reassignment never drops old contents (plain
`v = w` on a local LEAKS on the shipped compiler — MIR assign lowering
has no drop elaboration; blocks heap-owner bare-self and parts of #678)
and **#690** param rebinding rejected despite mutability.md. The
drop-audit skill (.claude/skills/drop-audit/) did NOT survive the
machine switch and is not in the repo — copy it from the old machine or
recommit it; this cycle substituted a --debug-alloc matrix. Remaining
D12: #678 (str) — delicate, interacts with §22. Section below is the
original map, kept for provenance.

**#689 RESOLVED as duplicate of #608's by-design ruling (2026-07-19):**
the "reassignment leak" is the A5/#606 narrow drop gate — POD-element
Vec buffers never free ANYWHERE (even plain scope exit) because the
compiler copies POD Vec headers as cheap handles; freeing would
double-free. The "wide flip" (Vecs own their buffers) is a deliberate,
UNSCHEDULED migration (#608 says refile as a project when scheduled).
User-Drop types drop-on-reassign correctly today (verified 1,2,2
allocator-silent). Two follow-ons for the maintainer: (1) the wide flip
is a candidate 8 GB-north-star lever (the compiler's own POD buffers
never free — part of the 4.9 GB frontend envelope); (2) D12 heap-owner
bare-self could be enabled for user-Drop-bearing owners now if wanted
(their assign-drop path already works).

### D12 (original map) — `mut fn` mutates in place on EVERY owner type  →  umbrella #644, impl #677 (scalar) + #678 (str)

**Ruling (decisions.md D12, canonized in 1a016f6a):** a `mut fn` receiver
borrows and mutates the caller's place for every owner type — scalar primitives,
`str`, distinct/newtypes over them, and aggregates alike.
`extend i32: mut fn bump(): self += 1` must make `x.bump()` mutate `x`.

**Governing principle:** the receiver **MODE** decides share-place, the owner's
type does not. `i32` is `Copy`, but `mut fn` still borrows in place (mode wins
over Copy-ness, exactly as for Copy structs). `f(x)` copies; `x.bump()` borrows.
`move self` stays consuming/owned. No new mechanism — this is D5 share-place /
`PassMode::IndirectPlace`, the same ABI aggregates use.

**Idiom (what the spec examples teach):** domain verbs on distinct/newtypes —
`distinct type Health = i32; extend Health: mut fn damage(n)` → `hp.damage(30)`.
Bare `i32.bump()` is legal but prefer the operator when there's no domain
meaning.

**Spec:** §9.5 (`docs/with-specification.md`, ~line 3662, after the receiver-mode
table) has the explicit primitive/str clause, the mode-over-type principle, and
the Health example.

**Implementation (NOT done — the single root-cause gate):**
`src/SemaDecl.w:1086 fn_param_uses_value_ref_abi` — line ~1089 excludes `str`
owners; line ~1093 restricts IndirectPlace to `TY_STRUCT`/`TY_GENERIC_INST`/
`TY_ENUM`. Primitives and str fall through to by-value, so `self += 1` mutates a
callee copy; after D7 enforcement this surfaces as the misleading
`cannot assign to immutable variable`.
- **#677 (scalar primitives, land first):** a non-`move` `self` on a scalar
  primitive (or distinct-over-scalar) owner returns share-place. Extend via
  `compute_fn_abi`/`PassMode` (D6) — ONE classifier read by both
  `declare_function` prologue and `push_call_arg`; never a per-path decision.
  Verify with `--dump-abi` (shows `SHARE-PLACE | OWNED | COPY` per param).
- **#678 (str/fat-pointer, delicate follow-on):** `str` is `{ptr,len}`
  (PassMode::Fat); IndirectPlace = `str*`, callee writes both fields. Distinct
  ABI shape + its own ephemeral/view-origin cell (§22): a `mut fn` reassigning
  `self` to a sub-slice must not outlive the source.
- **Both gated on `/drop-audit`** (`.claude/skills/drop-audit/`) — value shape ×
  control flow × ownership op × receiver mode. Run before AND after; one bad
  cell means the region is untested. This is the most delicate subsystem.

Both D11 and D12 were ruled **in scope for v0.16.0** ("do it right, now"),
not deferred.

---

## #665 — comptime HashMap Option convergence (LANDED bb31e86a, battery GREEN)

Confirmed: the full battery passed on bb31e86a (`GATES EXIT: 0` — all 9 targets,
FIXPOINT, audit violations=0, EMIT-C smoke, last-green recorded). The fix:
comptime `HashMap.get`/`remove` now return `Option[V]`
(was naked value — a per-phase type divergence); added `eval_option_method_call`
in `src/ComptimeEval.w` for comptime Option receivers (unwrap/expect/is_some/
is_none/unwrap_or). Closure-taking Option combinators (map/and_then/filter) and
#665 items 2 (comptime annotated-let generic inference) & 3 (user impl-methods
as comptime fns) remain — keep #665 open for those.

---

## This session's landed & closed work (context)

- **#549** (a3ae4f62) — value-position `if` branches that don't unify now
  diagnose; distinct-base unwrap keeps BlockId-vs-i32 joins accepted.
- **#630 message** (f0c627ca) — overflow panics name type/operation/wrap
  direction. (Issue stays open as the D11 impl vehicle.)
- **#656** (6f123492) — f-string holes preserve source-level backslashes
  (normalizer + lexer + hole-scanner all track nested-string context).
- **#657** (67587e78) — `std.time.now()` returns Unix-epoch seconds
  (`rt_wall_clock_sec` per platform); `now_ns()` stays monotonic.
- **#658** (49453206) — `std.net` TCP listen/accept + UDP bind implemented on
  Darwin/Linux (`-errno` surface, new `sock_port`/`udp_connect`). Windows has no
  net backend (deferred).
- **#668** (a7efb23a) + **#619** (33b064ea) — **emit-C cross-compilation loop
  CLOSED**: `with build src/main.w --emit-c` emits the full compiler (1.84M
  lines), a stock host `cc` builds it, and `with-from-c` re-emits itself
  byte-identically (`:emit-c-fixpoint`). #619's OOM no longer reproduces.
- **#638** (85870d3c) — `with fmt` inline `--prefer-brace`/`--prefer-colon`
  conversions; new `cli-selfhost-fmt-tests` target.
- Earlier: **#669/#670/#671/#637/#672** and **D10** (channel `recv()->Option`)
  all landed pre-this-file.

---

## Gate battery (run before EVERY commit; confirm `GATES EXIT: 0` as its own step)

```sh
(with build && with build :fixpoint && \
 ./out/stage/bin/with-stage2 analyze src/main.w audit:all && \
 WITH_MEMORY_LIMIT_BYTES=0 with build :test && \
 WITH_MEMORY_LIMIT_BYTES=0 with build :test-green && \
 WITH_MEMORY_LIMIT_BYTES=0 with build :last-green; echo "GATES EXIT: $?")
```

- ~40 min wall. Run in background; do NOT tail-truncate — grep the harness's own
  `ok:`/`error:` verdict lines and the final `GATES EXIT`.
- `WITH_MEMORY_LIMIT_BYTES=0` is required for `:test`/`:test-green`/`:last-green`
  on this high-RAM host (else `:last-green` alone can SIGKILL/125 at the memory
  cap even when tests pass).
- Never chain a commit/issue-close onto the tail of gate output — confirm the
  exit as a separate step first (memory `feedback_gate_check_before_commit`).
- Doc-only commits (spec/decisions/handoff) don't need the battery.
- Commit with explicit paths to keep unrelated in-flight changes out.

## Reseed — CURRENT (2026-07-18, third reseed of the day)

Installed seed `~/.local/bin/with` AND `src/main` = **v0.15.1-gf3c65c2d7**
(= HEAD f3c65c2d), both verified rc=0 with valid signatures; release asset
re-uploaded to match. The seed carries the COMPLETE #681 work: per-unit
generation (a497d145 / bc0c9832 / e6c770b9) plus the windowed emit
concurrency + strip-pipeline deletion (0a14b07c / 60dc5ec9). Reseed
sequencing landmine (hit live): committing ANYTHING between the battery
and `:update-seed` restamps the binary and require-last-green rejects it —
recover by rerunning `:test → :test-green → :last-green` (cheap; verdicts
key on with.unstamped, D13) then `:update-seed → :install-user` with no
commits in between. The first
`with build` after any reseed rebuilds the chain once (seed hash is a stage1
input — expected). **Verify every reseed with
`~/.local/bin/with --version; echo $?`** — an in-place overwrite of the
running signed binary can leave a stale arm64 vnode signature cache →
SIGKILL rc=137 (root-fixed in the installer 7ba518e2: temp-sibling + rename;
the stamp action now uses the same pattern, 0efd2552).

**Stale-machine recovery (hit live 2026-07-18):** a machine whose seed
predates a stdlib API that build.w names (`Target.allow_parallel`,
`write_tar_gz`) fails EVERY `with build` subcommand — including `:seed` — in
seconds with "unknown method ... / build.w evaluation wrapper compilation
failed". That fingerprint = stale seed, not a code bug. Recovery: gh-download
the `with-darwin-aarch64` release asset (re-uploaded at reseeds; check asset
`updatedAt`, not the release date), verify `--version`/ancestry, and
temp-sibling-install to BOTH `src/main` and `~/.local/bin/with`.

## Release posture (v0.16.0)

Queue-driven, not time-driven (maintainer: the queue IS the contract). Deferred
to milestone **post-v0.16.0**: the migration campaign #675→#673/#674/#676, all
Windows work (#369), and #650's remainder. In v0.16.0 scope: D11 (#630), D12
(#677/#678), and the remaining pre-release bug/coverage queue. Two rulings await
the maintainer's explicit go before implementation.

## Authorship / discipline

Eric Hartford is sole commit author — NEVER add AI co-author/trailer. Never
`git stash`. One logical change per commit. `-O1` always, never `-O0`.
Share-place (D5) / single-FnAbi (D6) / receiver-mode-keywords (D7) are load-
bearing — re-read `docs/completed/mutability.md` before touching parameter
passing. Vale (`.reference/Vale`) is the ownership reference; "safe as Rust" is
a bar, not a compass. All tooling in With (no sed/awk/python) — `with -e/-n/-p`.

---

# LANDED (2026-07-17): build-cache fix — post-link version stamp (#650)

**Status: full battery GREEN on this exact tree (`GATES EXIT: 0` — build,
FIXPOINT, audit violations=0, 1876 test files across 9 targets, EMIT-C smoke,
test-green/last-green recorded); committed on top of bb31e86a.** The change
spans `src/main.w`, `build.w`, `build/compiler.w`, `build/emit_c.w`
(emit-c paths consume `out/gen/versioned_main.w`, verify `--version` parity,
patch the roundtrip binary before byte-compare), `docs/decisions.md` (D13),
and this file.

## Root causes (exact)

1. `comp_write_versioned_source` substituted `v<base>-g<commit>` into compiled
   `out/gen/main.w`, so every commit changed a hashed compiler input.
2. The first post-link implementation left the combined `compiler-sources`
   action HEAD-sensitive. `src/main.w:1597` marks a completed dependency as
   rebuilt and `BuildGraphCache.w:466` makes its dependent stale, so stage1
   would still rebuild after every commit even when `out/gen/main.w` was
   byte-identical.
3. Patching the linked Mach-O invalidated the linker-created ad-hoc signature;
   arm64 AMFI killed the final binary with SIGKILL 9/rc 137.

## Implemented shape

- `src/main.w` embeds a 48-byte sentinel c-string and reads it NUL-terminated
  for `--version`; no commit text enters the compiled source.
- `compiler-main-source` owns stable `out/gen/main.w` and is the only generator
  in stage1's dependency chain. HEAD-sensitive bootstrap/version generation is
  isolated in `compiler-version-sources`; the public `compiler-sources` group
  still produces both sets.
- `link-compiler` produces untouched `out/release/bin/with.unstamped`.
  Downstream `build` tracks HEAD/`WITH_VERSION`, patches a distinct final
  output, and fails loudly for missing/truncated/oversized slots.
- On macOS the patch action runs `/usr/bin/codesign --sign - --force` through
  `ProcessRunner` after write/chmod. Failure is captured and returned nonzero.
- D13 in `docs/decisions.md` protects the architecture.

Comptime actions require the evaluator-supported methods: `data.find`, `"\0"`,
`fs.read_text`/`write_text`, and `fs.chmod`; raw runtime externs and an
interpreted byte loop over the ~100 MB binary are not viable here.

## Evidence already collected

- `with check build.w`: `ok`; `git diff --check`: clean.
- Final cold build after the target split: exit 0 in 11m33s; release link wrote
  `with.unstamped`, patch/sign completed.
- Version-only invalidation probe:
  `WITH_VERSION=v0.15.1-cache-probe with build` exited 0 in 13.9s with **no**
  stage/link markers; `link-compiler` remained `fresh`; final signature was
  valid and `--version` printed the probe exactly.
- Restoring the normal stamp took 13.9s, signature validation passed, and
  `--version` printed `with v0.15.1-g7dde992ff` (HEAD). `compiler-main-source`,
  `link-compiler`, and `build` all reported `fresh` afterward.

## Remaining queue

1. DONE — full battery green (`GATES EXIT: 0` confirmed as its own step).
2. DONE — committed. Post-commit `with build` is the real HEAD-change proof and
   must rerun only the cheap patch, not a stage/link.
3. Reseed/install: maintainer APPROVED this session ("reseed install"). One
   chain, no commits between: `:test → :test-green → :last-green →
   :update-seed → :install-user`; verify installed signature/version/exit code.

## LAPTOP-SWITCH STATE (2026-07-18)

The maintainer moved machines mid-campaign. What transferred and how:

- **Seed:** the `with-darwin-aarch64` asset on the v0.15.1 release is the
  live seed channel — refreshed at each reseed (check the asset's
  `updatedAt`, not the release publish date). Refreshed three times on
  2026-07-18: for the laptop switch (last fully-gated pre-#681 compiler),
  then to g2765fd4da (per-unit pipeline gated), then to **gf3c65c2d7**
  (complete #681 incl. windowed emit). `with build :seed`
  fetches it, but ONLY if the machine's current seed can still evaluate
  build.w; a too-stale seed fails EVERY subcommand including `:seed`
  itself (fingerprint + direct-gh-download recovery: see the Reseed
  section above). Keep the asset current after future reseeds — a stale
  seed asset silently strands every machine but the one that reseeded
  locally.
- **Not in the repo, copy manually if wanted:** the agent memory dir
  (`~/.claude/projects/-Users-eric-with/` — behavioral/feedback memories;
  project state is fully duplicated here and in docs/build_time_log.md)
  and `.deps/llvm-22.1.6-darwin-arm64` (rebuildable via
  `tools/build-static-llvm.sh`, ~hours).
- Background batteries running on the old machine died with it; that is
  why the battery had to be re-run (now DONE — next section).

## GATED (2026-07-18): e6c770b9 battery green; reseed delivered

The battery-first directive is DONE. Full battery on 2765fd4d (= e6c770b9 +
handoff doc): **`GATES EXIT: 0`** — build, FIXPOINT byte-identical through
the 16-unit per-unit pipeline, audit facts=2197572 violations=0, all 9 test
targets green (1876 files), test-green + last-green recorded. The 16-unit
default is deterministic and formally gated; nothing through HEAD is ungated.
The standing-approved reseed chain (`:update-seed` → `:install-user`) ran on
that green tree and verified (see Reseed section).

## CURRENT WORK: structural campaigns, one at a time (maintainer-directed)

Order agreed 2026-07-18: **#681 → #682 → #683**, then the north-star
campaign: **peak build memory UNDER 8 GB** (compiler buildable on an 8 GB
machine, Mac/Linux/Windows).

**#681 state: COMPLETE (all tiers landed, pushed, and GATED).**
- 88ade44f disposal quick tier; a497d145 MIR-via-raw-pointer (the sharing
  contract; the ~490 sites go through typed in-place-deref accessors —
  NEVER a ref-returning accessor, that shape segfaults, filed #687);
  bc0c9832 per-unit generation from MIR (serial gen, one cg alive at a
  time + parallel slim emit over ~1/K-size unit bitcodes); e6c770b9
  16-unit default (GATED 2026-07-18 — see the GATED section above).
- Measured: peak RSS 21.1 → 13.2 GB (−37%) at 8 units; 16 units 149.2 s /
  15.5 GB (old pipeline: 170.9 s / 30.5 GB). Fixpoint byte-identical;
  drop-audit 25/25; produced compiler self-checks.
- Key mechanisms a future reader needs: fn_sym-keyed plan from MIR
  statement counts (dual-keyed sema+cg-intern in unit_assign); Pass-2/
  mir-only/generator-next filters; __wcu$<idx>$ declare-time promotion of
  would-be-internal planned fns; synthesized fns pinned to unit 0 with
  main force-assigned there; deterministic post-gen demotion walk for
  foreign external definitions (synthesized prelude trait defaults — the
  bring-up's one link failure); global-ownership surgery shared with the
  old strip.
- #681 leftovers DONE 2026-07-18 (late session), each on its own green
  battery: dead strip pipeline deleted (60dc5ec9, −221 lines); windowed
  emit concurrency landed (0a14b07c). Verification finding that reshaped
  it: peak is K-INDEPENDENT under full concurrency (15.3 GB @ K=5 / 13.2
  @ K=8 / 14.4–15.5 @ K=16), so the old mem-cap-on-K never protected
  small hosts — memory now bounds in-flight EMIT THREADS (join-oldest
  window; W = (mem − 5 GiB) / (plan_cost × 36 KB / K); K = cores only).
  Forced W=2: peak footprint 10.03 → 7.76 GB at +47 % wall; W=K big-host
  behavior byte-identical (fixpoint green). Policy is a leaf module
  `compiler.CodegenUnitsPolicy` with a 21-cell internals matrix — leaf
  because test files cannot import Mir-adjacent modules (**#688**, new).
  `WITH_CODEGEN_EMIT_WIDTH` overrides. #681 CLOSED; real-8GB-hardware
  verification moves to the north star (needs #682/#685 frontend shrink —
  the 4.9 GB frontend envelope dominates the small-host budget). Serial
  per-unit sema/intern re-copy (~1 s × K) left as optimize-if-it-shows.

**Next campaigns in order: #682 (prelude snapshot) → #683 (compiled build
graph) → the 8 GB north star (remaining residency: frontend 4.9 GB
measured — #685 arenas/slab-release + #682 both attack it; the emit side
is now windowed).** Experiment log: docs/build_time_log.md (the full
measured record of every kept and rejected change).

**#683 state: substantially DONE (c81e8173, battery-green, reseeded
gc81e81739 + asset).** Serial build.w actions now run in-process in the
driver — the per-action worker child (a full build.w re-eval, ~0.85–1.6 s
each) is gone; commit-shape rebuild 13.9 → 10.4 s (−25 %). Remaining
floor: pooled children still re-eval per action (~3 s wall per cold
build, hidden by parallelism) and one re-eval per test target — judged
not worth a worker-slice protocol; the serialized-graph idea is subsumed
by #682's machinery if it ever matters. Issue closed with measurements;
reopen if the resweep of pool-width hosts says otherwise.

**#682 state: DESIGNED, not implemented** — full design + increment plan
in the 2026-07-18 issue comment; implement in a fresh session against it.
PREMISE CORRECTION recorded there: measured prelude cost is ~25 ms per
invocation on the 18-core host (~3–5 s wall per battery), not the study's
"minutes" — #682's real value is as the pathfinder for #684 module
interfaces. Maintainer may re-weigh #682-now vs #683-first on those
numbers; order stands until they say otherwise. Key facts: prelude-closure
AST/intern IDs currently land AFTER user decls (user-dependent offsets) —
increment 1 is prelude-first prefix ordering, the risky reordering step,
landed alone. Sema is SoA Vec[i32] + HashMaps (dump raw + rebuild-on-load
respectively). Snapshot keyed on with.unstamped + prelude mode, stored
per-tree under out/.build-state/.

## Build-performance campaign (2026-07-17 session, maintainer-directed)

The maintainer ruled the ~40-min battery unacceptable and directed "fix this
issue deeply." Evidence base: `docs/build-perf-reference-study.md` (multi-agent
comparison vs `.reference/{go,rust,swift,Vale,zig}`; 10 adversarially-verified
deltas). Landed this session:

- **c3de4c0b** — per-target wall-time instrumentation in the graph executor
  (`[time]` lines + `out/.build-state/build-times.tsv`). First measurement
  ever: stage1 175.9s + stage2 174.3s + link 173.0s = 77% of `with build`
  (681s total); the ~30 runtime objects are a serial ~90s tail.
- **4dcf9419** — test verdicts keyed on `with.unstamped` (D13: stamp is
  provenance). PROVEN: restamp with a different version → verdicts stay
  cached. Commits no longer invalidate ~1900 banked test passes.
- **196056ac** — test runner defaults to host-core width (was 4 on 16 cores;
  `WITH_BUILD_TEST_JOBS` still overrides, cap 32) with a join-oldest sliding
  window instead of the spawn-4-join-all batch barrier.
- **:dev target + D14 tiering policy** (this batch) — iterate = `with check`
  / `with build :dev` (seed→stage1); battery gates commit batches;
  independent build-layer changes share one battery, land as separate
  commits; audit:all ∥ :test concurrency sanctioned. CLAUDE.md amended.
- **Stamp temp-sibling hardening** (this batch) — `comp_patch_version_binary`
  writes/signs `with.tmp` then renames; in-place write corrupted a running
  binary at that path (self-seeded rebuild hazard).

**Measured effect:** commit-only rebuild 16s (was ~12 min); test leg ~8 min
at core width (was ~22); post-reseed a non-compiler commit's battery ≈
build 16s + cached verdict sweep.

### Structural arc — FILED as the #679 campaign (dependency order)

- **#679** umbrella: full verification ≤10 min / ≤8 GB; invariants that do
  not bend (self-hosting, -O1, per-commit fixpoint, no external deps).
- **#680** parallel build-graph executor with memory-claim admission (d8).
  **Stage A LANDED** (76c6d969 audit + 0262e1ed edges): the build closure
  audits clean — zero declaration-order-dependent edges; single-writer per
  invocation already guaranteed by validate_outputs.
  **Stage B LANDED + MEASURED** (a2413f2e machinery + 44ab0d26 markers, with
  an intermediate reseed — build.w cannot name a new stdlib API until a seed
  embeds it): `Target.allow_parallel()` pools pure compile actions as
  captured workers at cores/2 width (`WITH_BUILD_JOBS` override);
  declaration order stays program order; pool drains before unmarked
  execution. Full chain: 684.2s vs 757.8s serial (~10%); fixpoint stayed
  byte-identical. Remaining build time is the serial stage chain itself
  (83%) — #684's territory. Stages C (delegate in-process kinds) and D
  (memory-claim admission) remain, each its own cycle. LANDMINE: std.build
  Target has three full copy-literals (Target.target/optimize/output) that
  must gain any new field, else the embedded stdlib breaks and only behavior
  tests spawning out/stage/bin/with-stage2 catch it.
- **#681** codegen-unit windowing + dispose base module/MIR pre-fan-out (d2)
  — the >30 GB peak; /drop-audit gate if lowering is touched.
- **#682** serialized prelude snapshot keyed by compiler fingerprint (d6).
- **#683** compile/serialize the build graph once; stop re-interpreting
  build.w per worker (d9; the measured ~1.1s/action floor).
- **#684** separate compilation with module interfaces (d5) — the only fix
  for the 175s-per-stage constant; prerequisites #680+#682; sequence LAST.
- **#685** allocator slab release + phase arenas (d7).
- **#686** over-invalidation: build.w-only edits rebuild the stage chain
  (CONFIRMED live 2026-07-17); regex-runtime-ir built twice per cold build.
