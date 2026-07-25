# Bootstrapping the With compiler — the replayable ladder

With is self-hosting: the compiler is written in With and compiles itself.
That creates a chicken-and-egg problem — you need a With compiler to build the
With compiler. This document explains how the chain is anchored to public
binaries, and the one law every commit on this branch obeys so that the chain
never breaks again.

## The law: a rule lands before its first use

**Every commit must be buildable by the compiler built from its immediate
predecessor.** A commit may *teach* the compiler a new rule (a new receiver
effect, a new ownership contract, a new map-view type). It may not, in the same
commit, *depend on* that rule in the compiler's own source. Teaching and using
are two commits, in that order.

This is the invariant that upstream `main` violated twice (D21's pipeline rework
and the D22 map-view flip both landed rule-and-use in one commit, `e5c84325`),
which is why the head-semantics compiler could not compile head. This branch
restores the invariant by rewriting that stretch of history into a ladder where
each rung is reachable from the one below it.

## Trust anchors (public releases on `withlang-dev/with`)

The chain is not "trust me" — it bottoms out in published, hash-verified
binaries anyone can re-run.

| Rung | Tag / release | Commit | What it is |
|------|---------------|--------|------------|
| 0 | `v0.15.1` asset `with-linux-x86_64` | (pre-D17) | Darwin-cross seed; the oldest public linux binary. |
| 1 | `seed-d17-0c87593c` asset `with-linux-x86_64` | `0c87593c` | D17 (`move place`). Hash-verified round-trip. Builds rung 2. |
| 2 (source) | `seed-d21-bridge` | `e4f96789` | `0c87593c` + two diagnostic relaxations. The **cross-semantic bridge**: it accepts D21 receiver effects and implicit consuming moves without yet *using* them, so it can build the first D21 rung. |
| 3 | `seed-head-selfhost-d22` | tip of this branch | The self-hosting head. Its stage2 == stage3 byte-identically. |

## The ladder (this branch, `0c87593c` → tip)

Read bottom-up; each rung is built by the compiler from the rung below it.

```
0c87593c  D17: move place                         ← rung 1, PUBLIC BINARY
   … #702 build/analysis, #697/#691 backend …     (built by rung 1)
323df635  serialized graph cache (last pre-D21)
65037979  I1 — accept D21 receiver effects,        ← the interstitial:
          retire D5 call-site move ceremony           teaches the rule,
                                                       does NOT use it.
                                                       (== the seed-d21-bridge
                                                        principle, committed)
daaa0c33  D21 pipelines (now the rules exist)       (built by I1's compiler)
   … D22 doctrine (Eric ruling, plan) …
   … D22 coverage: contextual-Copy materialization,
     if/match join, transparent origins, non-Copy
     copy-out — all carrying get as owned Option[V]
     so every rung stays predecessor-buildable …
0e64abbf  D22 Stage 6 — land the map-view flip:      ← get becomes Option[&V].
          get -> Option[&V]                             Built by the owned-
                                                        Option[V] predecessor
                                                        (cross-semantic bridge);
                                                        fixpoints byte-identical.
```

### Why the two bridges are sound

The two rungs that change a language contract (I1/D21, and the Stage-6 flip)
are each buildable by their predecessor because the change is **observationally
transparent to the compiler's own source**:

- **I1 / D21 receiver effects.** The pre-D21 compiler already accepts the
  receiver *spellings* head uses; I1 only relaxes the *diagnostics* that would
  reject D21's effect annotations. No pre-D21 call site changes meaning.
- **The map-view flip.** `HashMap.get` returning owned `Option[V]` versus
  borrowed `Option[&V]` is observationally identical for the compiler's own
  read-only lookups (it reads the value and drops the option; it never relies on
  ownership transfer from `get`). So the owned-lookup compiler compiles the
  borrow-lookup source unchanged. This is the same trust model GCC uses: stage 1
  built by an approximating compiler is allowed to differ; trust is established
  when **stage2 == stage3**.

## Replay recipe

```sh
# 1. Fetch the anchor binary (rung 1).
gh release download seed-d17-0c87593c -R withlang-dev/with -p with-linux-x86_64
chmod +x with-linux-x86_64                      # this is your seed

# 2. Walk the ladder. For the two bridge rungs, build with the PREDECESSOR
#    compiler; everywhere else the same-semantics compiler suffices.
#    The build env (LLVM SDK in .deps, link shim) is described in the runbook.
export WITH=./with-linux-x86_64
with build :stage1        # seed  -> stage1
with build :stage2        # stage1 -> stage2
with build :fixpoint      # stage2 == stage3, byte-identical  ← the proof

# 3. The tip's object fixpoint sha is recorded alongside the
#    seed-head-selfhost-d22 release; it must match.
```

## What is machine-verified vs. structurally guaranteed

Honesty about the proof boundary:

- **Machine-verified.** The tip's compiler source is byte-identical to the
  independently fixpoint-proven tree (`8181ce2a`), whose stage2 and stage3
  objects are byte-identical (`build --emit-obj out/gen/main.w -O1`). At `-O1`
  codegen is deterministic, so identical source ⇒ identical object; the tip
  inherits that fixpoint by construction.
- **Anchored, not yet each-rung-rebuilt in CI.** The rung-by-rung claim ("each
  commit builds from its predecessor") is realized for the load-bearing bridges
  — rung 1 is a hash-verified public binary, and the I1 bridge is the published
  `seed-d21-bridge` that was built and produced a working stage1. A fully
  automated walk of *every* rung is the linux-CI goal (#14); until that lands,
  the machine-checked span is `0c87593c..tip`, anchored beneath by the `v0.15.1`
  public seed.

## Invariant, going forward

`head compiles head` is a hard gate, not an aspiration. Any commit that would
make the head-semantics compiler reject head source — a contract change used in
the same commit that introduces it — is a ladder break and must be split into a
teach-then-use pair, exactly as the D22 flip is split here.
