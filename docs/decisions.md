# Decision Log

Architecture/design decisions and *why* we made them. Newest first. Each entry
records the decision, the context, the alternatives weighed, and the reasoning —
so a future maintainer (or agent) does not re-litigate a settled call, and can
tell whether a later fact should reopen it.

Format per entry: a short ID + title, date, status, and the reasoning. When a
decision supersedes an earlier one, say so in both.

---

## D19 — Verification cost scales with blast radius; batteries bless batches

**Date:** 2026-07-22
**Status:** Accepted.
**Deciders:** Eric (BDFL)

**Decision.** The full battery blesses a BATCH of commits, not each commit;
per-change verification is the iterate tier (`with check` / `:dev` +
targeted tests). Only ownership/drop, codegen-determinism, and ABI changes
must sit alone in their batch (with the drop audits). Corollary for the
build system itself: a request must cost what it names — installing a
blessed artifact is a manifest check plus a file copy, never a graph
evaluation (the `:update-seed`/`:install-user` fast path), and evidence is
written once by the step that produces it, only read thereafter.

**Why.** Battery-per-change grew from real incidents, but at ~20–40 min per
battery it made a day of small commits cost hours of redundant
recompilation of the same 160k lines (#684 measures the constant). Process
is a resource with the same failure mode as memory: obligations allocated
per incident and never freed. Verification depth now follows risk, and the
gates themselves must not re-derive what the battery already proved.

**What would reopen this.** A regression that a batched battery localized
too slowly to bisect — that argues for faster builds (#684), not more
batteries.

---

## D18 — Leak-freedom is a language invariant, not an optimization target

**Date:** 2026-07-22
**Status:** Accepted (mission-level ruling; mission.md amended).
**Deciders:** Eric (BDFL)

**Decision.** Making a memory leak must take deliberate, visible effort.
Every allocation is owned from the moment it is made — by the handle that
holds it, not by virtue of what it contains — and its owner's scope releases
it, compiler-proven. This supersedes the *provisional* status of A5/#608
("POD-element buffers leak by design"): that state was always scheduled to
end with #691, but as an optimization/scheduling matter; it is now a
mission violation with the flip as its first (not final) installment.

**The conceptual root cause (recorded so it cannot recur).** The 2026-07-22
memory campaign (issues #701–#703) traced every observed leak class — POD
Vec/str buffers, `++` rebuild-and-abandon chains, extern-returned strings,
per-call interpreter frames, ~890 concurrent accumulation ladders in the
build runner — to one chain of design errors:

1. *Reclamation was coupled to the wrong predicate.* One flag
   (`type_needs_drop`) answered two orthogonal questions: "does dropping
   this have user-observable effects?" and "does this value own heap?"
   Ownership was derived from a value's CONTENTS (POD elements ⇒ no drop)
   instead of from the HANDLE (it allocated; it owns). A `Vec[i32]` owns a
   buffer no matter how trivial its elements are.
2. *The obligation had inverted polarity.* Sound RAII makes "every
   allocation has an owner charged with freeing it" the default and makes
   opting out explicit. With made obligation the exception (Drop impls)
   and leak the default for everything else. Dead values from
   reassignment (`s = s ++ x`) had no scheduled release at all.
3. *Allocation paths existed outside the model.* Extern fns returning
   heap values (`with_fs_read_file -> str`) recorded no ownership fact;
   nobody was ever charged with the free. The runtime's own primitives
   must live under the same discipline (vec_grow already frees its
   superseded buffer — the discipline is achievable at every layer).
4. *Nothing forced the provisional state to end.* Leaking is memory-safe,
   so no gate tripped: the allocator was invisible to platform tools, the
   debug ledger truncated at scale, and there was no leak gate in the
   battery. A "temporary" decision with no forcing function is permanent.
5. *The mission bar was borrowed, not derived.* "Exactly as safe as Rust"
   imported Rust's frame — and Rust defines leaking as safe (mem::forget
   is safe). The invariant that IS this language's identity — the `with`
   scope releases what it holds — was never written down, so every
   downstream decision could trade it away without contradiction. Vale,
   our chosen ownership reference, gets this right: linear values MUST be
   consumed; there is no silent forget. We adopted Vale's machinery and
   initially skipped the one property that guarantees leak-freedom.

**Consequences.**
- #691 (the flip) is the first installment: heap-owning handles get
  scope-end release regardless of element POD-ness, and reassignment
  releases the superseded value.
- Extern signatures returning heap values must carry an ownership
  contract; an extern `-> str` means caller-owned with a scheduled drop,
  or must be spelled borrowed. No allocation path outside the model.
- Deliberate leaking gets a loud spelling (explicit forget/arena types
  with named scopes), never a silent default. Long-lived memory is owned
  by a named scope (`with arena:` …), which is the language's own idiom.
- The battery gains a leak gate (debug-alloc leak count = 0) once the
  flip lands, and the #702 8GB runner budget is the flip's acceptance
  test. Observability keeps the invariant honest: WITH_ALLOC_SYSTEM=1
  (leaks/Instruments visibility) and #703 (scalable ledger with site
  attribution) exist so a leak is always one command away from a name.

**What would reopen this.** Nothing short of a mission change. Performance
work may batch or arena-ize releases (an arena is an owner with a named
scope) but may not reintroduce ownerless allocations.

---

## D17 — Consuming a field writes the root; `move` applies to a place

**Date:** 2026-07-21
**Status:** Accepted.
**Deciders:** Eric (BDFL)

**Decision.** Ownership-forcing effects (consume/escape_value) do not cross
a NON-COPY projection: a callee that consumes a FIELD of a place blanks the
field (reset-on-move, §2.5.1) and leaves the root's place valid-but-changed
— a WRITE on the root, never a consume of it. A `mut fn` receiver therefore
suffices for methods that hand a field to a consuming callee; the
`move fn` escalation cascade (#691's 57 blocked methods, the promotion
`audit_receiver_projection_origins` already branded incorrect) is gone.
Alongside it, `move` applies to a place: `f(move self.r)` is the explicit
spelling; the field is blanked through whatever pointer reaches the base
(#697 machinery), so the caller's later drop skips it. POD-field moves are
plain copies. The required-move rule for plain non-Copy args and §2.4's
partial-move ban for Drop-impl owners are unchanged.

**The Copy-projection distinction (load-bearing).** A COPY-typed projection
(raw pointer, handle) keeps the old promotion: escaping it captures the
root's CONTENT by aliasing — nothing is blanked, so demoting to write would
be unsound for lifetime reasoning. std/thread.w's `@[effect(worker:
escape_value)]` pin on spawn_os caught exactly this during implementation
(the transmuted fn value escapes via a Copy fn_ptr field) — the effect-pin
feature enforcing its contract as designed.

**Alternatives weighed.** Keeping the promotion forces `move fn` on every
method that consumes any field, transitively — Rust-shaped virality that
made the compiler's own driver API unusable under the #691 flip. Weakening
without the Copy guard breaks aliasing-escape contracts (the pin caught
it). Threading `&mut`-style out-params instead is forbidden by §1.4/§3.3.

**Enforced by:** the m-probe matrix in the D17 commit, `--dump-abi`
verdicts (field-consuming receiver: eff=[write] SHARE-PLACE), drop-audit
field_take cells, and the #697/#698 debug-alloc fixtures. Would reopen on:
per-field effect summaries (which could carry field-precise consume without
promotion), or a change to reset-on-move that makes field blanks
observable.

---

## D16 — `move x` is rvalue-uniform: it always moves, callee-independent

**Date:** 2026-07-21
**Status:** Accepted.
**Deciders:** Eric (BDFL)

**Decision.** `move x` at a call site always moves: the value is materialized
as a statement temporary and the source binding is reset immediately. An owned
(consuming) callee consumes the temporary through the call; a share-place
callee borrows the temporary, which is destroyed at the end of the enclosing
statement (§2.4's temporary rule). `move x`'s caller-visible contract is
therefore callee-independent: after the statement, the binding is invalid and
the value is gone. The required-move error for plain non-Copy args to owned
params is unchanged; there is NO diagnostic for `move` into a borrowing callee
— post-ruling it is meaningful (early destruction), not noise.

**Context.** Before this ruling, `f(move x)` into a share-place param
borrowed: the binding was statically invalidated but the value silently lived
until the caller's scope exit — a deferred-drop lie (a lock/fd moved into a
consumer for deterministic release stayed held), contradicting mutability.md's
satisfaction table ("move x … yes, owned"). Found while grounding #697/#691.

**Alternatives weighed.**
- *Make it illegal* (`move` iff callee consumes; Rust/Vale make the construct
  inexpressible by typing): fails the no-ceremony diagnostic bar — after this
  ruling the construct has a well-defined, harmless meaning, and an error
  would force interaction about nothing (the same test that forbids must-use
  Result ceremony). Also an instantiation-dependent legality cliff for generic
  forwarders (effects are inferred per specialization), and callee body edits
  (consume → read) would break every `move` caller.
- *Warning*: post-ruling the operation does something (early destruction);
  warning on meaningful code is noise.
- *Status quo*: a silent RAII-timing surprise.

**References.** Swift is the only reference language with the exact construct
and chose the same semantics (OwnershipManifesto: `move(x)` yields an rvalue
and leaves the variable uninitialized; reinit heals a `var`; a temporary
passed to a borrowing parameter dies at end of the full expression). Rust's
`Operand::Move` passes call arguments "in-place — the callee might just get a
reference to this place" with the source set to uninit: uniform pointer ABI,
ownership follows the contract (D6 stays intact). The implementation may later
elide the temporary copy by aliasing the source storage; this entry fixes the
semantics, not the materialization strategy.

**Enforced by:** test/debug_alloc/da_move_into_shareplace_timing.w (timing),
drop-audit cell move_into_borrow/bare (exactly-once). Would reopen on: a
share-place ABI change that makes borrowing a doomed temporary unsound, or a
future explicit parameter-mode syntax that makes callee modes visible at the
declaration.

---

## D15 — One loop back-edge carried-move predicate; `break` is a separate edge

**Date:** 2026-07-20
**Status:** Accepted.
**Deciders:** Eric (BDFL)

### The decision

The move checker's "is this binding used moved on the next iteration?" test is
computed by a single pure predicate — `is_loop_carried_move(entry_state,
cur_state, needs_drop)` = `entry==LIVE && cur==MOVED && needs_drop` — that BOTH
loop back-edges call: the fall-through (`finalize_loop_move_state`) and the
`continue` (`check_loop_continue_carried_move`), including their
`WITH_TRACE_MOVE` verdict lines. Re-inlining the condition per edge is
forbidden.

`break` (`capture_loop_break_move_state`) is deliberately NOT folded into this
predicate. It is an **exit** edge: it propagates the current move-state *out* of
the loop into the post-loop state (any binding MOVED at a break is MOVED after
the loop). It has no `entry==LIVE` guard because that is correct — it is not a
carried-move error, it is a different operation. A future maintainer should not
"unify" break with the back-edge predicate; that would be wrong.

### Context / why

#696: the `continue` back-edge check had drifted from the fall-through check —
it fired on `cur==MOVED` alone, dropping the `entry==LIVE` guard, so a value
moved *before* a loop with a `continue` was wrongly flagged as moved *inside*
it. It shipped in #613 with zero tests. Root cause was per-edge re-derivation of
one predicate — the same failure mode D6 forbids for call ABI ("`FnAbi` is the
single ABI source of truth — never re-derive call ABI per-path"). The instance
fix (give continue the loop-entry snapshot) is not enough on its own: with the
condition still inlined at two sites, a third back-edge could reintroduce the
divergence. So we make the guard structural — a caller cannot invoke the
predicate without supplying the entry state.

### Alternatives weighed

- **Leave both sites inlined (instance fix only).** Rejected: that is what let
  #696 exist; nothing stops the next edge from drifting.
- **Also unify `break`.** Rejected as incorrect — break is an exit edge, not a
  back-edge; it has different (correct) semantics.

### What guards it / would reopen it

`tools/move_audit.w` (`with build :move-audit`) is the behavior matrix over
(edge × move-timing × shape); it proved this refactor neutral (15/15 cells) and
would catch a future re-divergence. See D6 (single-source-of-truth ABI) and
D14 (battery tiering).

---

## D14 — Verification tiering: iterate on one stage; battery gates commit batches

**Date:** 2026-07-17
**Status:** Accepted — maintainer-directed ("fix this issue deeply").
**Deciders:** Eric (BDFL)

### The decision

- **Iterate tier:** while developing, verify with `with check` and/or
  `with build :dev` (seed → stage1, ONE self-compile, ~3.5 min to a testable
  binary at `out/bootstrap/bin/with-stage1`) plus targeted test files. No
  battery per edit.
- **Commit tier:** the full battery (build, fixpoint, `audit:all`, `:test`,
  `:test-green`, `:last-green`) gates every commit batch. `audit:all` and
  `:test` may run **concurrently** — they share no outputs (audit needs
  stage2, tests need the release binary), and audit's ~6 min hides inside the
  test leg.
- **Batch rule:** independent, low-risk build-layer changes (build.w,
  build/*.w, docs, non-semantic executor changes) may share ONE battery and
  then land as separate per-change commits. Anything touching language
  semantics, codegen, ownership/drop scheduling, or ABI keeps the strict
  battery-per-change rule.
- **Fixpoint stays in the commit tier unconditionally.** The references argue
  convergence from cache keys (Go) or defer the byte-diff to release CI
  (Zig); With's per-commit byte-fixpoint is stronger and has caught real
  nondeterminism. The waste was repeating it per *edit*, not having it.

### Context / why

Measured 2026-07-17 (`out/.build-state/build-times.tsv`, first data from the
D-instrumented executor): stage1 175.9s + stage2 174.3s + link-compiler
173.0s = 77% of an 11.4-min `with build`; the full battery was ~30-40 min.
Three consecutive ~30-min batteries were spent landing three independent
build-graph changes where one batched battery carried identical evidence —
~1 h of pure ceremony in a single session. Every reference compiler tiers
verification (Rust `x build` = stage 1 by default; Zig's dev loop is one
self-compile with fixpoint in release CI only; Go primes its cache for
iteration). See `docs/build-perf-reference-study.md` for the evidence trail.

### What would reopen this

A regression that a batched battery passed but per-change batteries would
have isolated (and that bisection could not); or a recurring bug class that
`check` + stage1 misses and only stage2 exposes, making the iterate tier
untrustworthy.

---

## D13 — Commit-derived compiler versions are post-link metadata, never compiled inputs

**Date:** 2026-07-17
**Status:** Accepted — implementation tracked by #650. **Deciders:** Eric (BDFL)

### The decision

The compiler's commit-derived version is provenance metadata. It must never be
substituted into generated source, object code, or any other hashed input of the
native compiler stage/link chain. The expensive compiler build embeds a stable,
fixed-width sentinel and produces `with.unstamped`; a separate cheap `build`
action tracks `.git/HEAD`, its resolved ref, and `WITH_VERSION`, patches the
real version plus NUL into a distinct final `with` output, and fails loudly if
the slot is missing, truncated, or too small.

The stage chain depends only on the commit-independent generated main source.
Versioned bootstrap/version artifacts live behind a separate target: a target
that tracks HEAD cannot be a stage dependency even when its relevant output is
byte-identical, because the build cache deliberately invalidates a target when
any dependency rebuilt.

On macOS, patching invalidates the linker's enforced ad-hoc code signature, so
the patch action must ad-hoc re-sign the final binary after writing and chmod.
Linux and Windows do not run that signing step.

### Context / why

The cache was already content-addressed, but every commit changed
`out/gen/main.w` by substituting `v<base>-g<commit>` before compilation. That
made documentation-only commits rebuild the full self-hosted compiler. Keeping
the generated main byte-stable was necessary but not sufficient: the original
combined source-generation action still tracked HEAD, and
`build_cache_freshness_reason` treats a rebuilt dependency as stale, so stage1
would still rebuild after every commit. Separating stable and versioned source
generation removes both invalidation paths.

The version suffix does not affect compiler semantics, fixpoint identity, or
artifact correctness; it is late-bound provenance. Post-link stamping preserves
the exact user-visible version while keeping semantic build inputs truthful.

### Protection / the rule going forward

- Never restore version substitution in `out/gen/main.w` or another native
  compiler input.
- Keep the unstamped link output separate from the patched output; modifying a
  target's own cached output in place makes that target perpetually stale.
- Do not attach HEAD/version inputs, directly or through a rebuilt dependency,
  to the stage chain or `link-compiler`.
- Preserve the loud slot bounds/sentinel checks and the macOS re-sign step.

---

## D12 — `mut fn` mutates in place on every owner type; the receiver MODE decides share-place, not the owner's type (primitives and str included)

**Date:** 2026-07-17
**Status:** Accepted — BDFL ruling. **Deciders:** Eric (BDFL)

### The decision

A `mut fn` receiver borrows the caller's place and mutates it in place for
**every** owner type — scalar primitives (`i32`, `u64`, `f64`, `bool`,
`char`, …), `str`, distinct/newtypes over them, and aggregates alike.
`extend i32: mut fn bump(): self += 1` works: `x.bump()` on a `var x`
mutates `x`. The lowering is D5 share-place / `PassMode::IndirectPlace`
(a pointer to the caller's slot) computed once by `compute_fn_abi` (D6) —
the same ABI aggregates already use — so no new mechanism is introduced;
the previous restriction to STRUCT/GENERIC_INST/ENUM owners was an
incompleteness, not a design.

**The governing principle: the receiver MODE decides share-place, the
owner's type does not.** `i32` is `Copy`, but `mut fn` still borrows in
place, because mode wins over Copy-ness — exactly as it already does for
Copy structs. `f(x)` (by-value param) copies; `x.bump()` (`mut fn`
receiver) borrows. `move self` stays consuming/owned (not share-place);
plain `fn`/`&self` on a Copy scalar may pass by value (read-only, no
observable difference).

**Idiom:** the blessed use is domain verbs on distinct/newtypes
(`Health.damage(n)`, `Money.add(m)`), not bare `i32.bump()` — when there
is no domain meaning, prefer the operator (`x += 1`). The spec examples
lead with distinct-type domain modeling (the app-dev audience).

Rejected: **Option B** (keep rejecting `mut fn` on primitive/str owners
with an honest diagnostic + a §9.5 carve-out). B bends the spec to a
current ABI limitation — backwards from spec-leads-compiler — and denies
app devs an ergonomic the two closest references ship in their own
standard libraries.

### Context / why

`extend i32: mut fn bump(): self += 1` compiled to a callee-copy mutation
that never reached the caller; after D7 enforcement it became a loud but
MISLEADING compile error ("cannot assign to immutable variable"). Root
cause is one gate: `SemaDecl.w:1086 fn_param_uses_value_ref_abi` excludes
`str` (line 1089) and restricts IndirectPlace to aggregate owners
(line 1093), so primitive/str receivers fall through to by-value.

Reference filter (verified in .reference/ checkouts): **Swift**
`Integers.swift:327 public mutating func negate()` ships a mutating
method on a primitive in the standard library — and `extension Int {
mutating func }` is the near-exact twin of With's `extend i32: mut fn`.
**Rust** `core/num/mod.rs:720 pub const fn make_ascii_uppercase(&mut
self)` ships a `&mut self` mutating method on a primitive in `core`.
**Go** (`time.go:226 func (t *Time) stripMono()`) mutates via
pointer-receiver on a named type. Unlike D11's 3-2 split, this is
effectively unanimous that the mutation must reach the caller: every
reference that lets you attach a mutating method to a value/primitive
receiver makes it work.

Mission filter: §9.5 already promises "mut self mutates in place"
generically with no primitive carve-out — so this is spec-leads-compiler
(the spec is right, the impl was incomplete). Ergonomics-first wants
`hp.damage(30)` over `hp = Health(hp.value - 30)`. "Safe as Rust" is a
bar, not a compass — share-place on a primitive is exactly as safe (the
borrow is exclusive for the call, D5); nothing becomes silently wrong.

Builds on D5 (share-place calling convention), D6 (`FnAbi`/`PassMode`
single source), D7 (receiver-mode keywords). Sibling of D11 (both are
core-type surface rulings taken in-scope for v0.16.0 rather than
deferred).

### Scope / implementation

In v0.16.0 (maintainer: "do it right, now" — NOT deferred). Two shapes,
tracked as implementation issues under umbrella #644:
1. Scalar primitive owners → IndirectPlace (`i32*`-style): **#677**.
2. `str` / fat-pointer owners → IndirectPlace over the `{ptr,len}` fat
   pointer (distinct ABI shape; own drop/lifetime audit cell): **#678**.
Both gated on the `/drop-audit` matrix (value shape × control flow ×
ownership op × receiver mode) per the receiver-ABI-change rule.

### What would reopen this

A drop/lifetime cell that cannot be made sound for a share-place scalar
or fat-pointer receiver without violating D5's exclusive-borrow contract.

---

## D11 — Collection length is signed: len() -> Int (i64); no Option wrapper; C's -1 conventions stay at the binding layer

**Date:** 2026-07-17
**Status:** Accepted — BDFL ruling. **Deciders:** Eric (BDFL)

### The decision

`.len()` on every collection (Vec, HashMap, HashSet, BTreeMap, BTreeSet,
str, slices, arrays, SlotMap, VecRange) returns **`Int` (i64)**, not
`usize`. Length is never wrapped in Option. C conventions that encode
absence or failure in a size (null container pointers, `ssize_t -1`)
are translated at the modeled-C binding layer, never inherited by the
core container types. The narrowing family stays: `len32()`/`ulen32()`
panic on overflow as before; `len64()` becomes an identity alias of
`len()` and remains for compatibility.

This supersedes the §18.6 usize contract (the 28d6343c len-family
design). The BTreeMap/BTreeSet `len() -> i64` declarations, previously
a spec violation, become the conformant shape.

### Context / why

`v.len() - 1` on an empty Vec panicked with an unsigned-underflow trap
(#630) — the famous Rust `0..v.len()-1` wart, imported wholesale. The
maintainer's first design instinct (Option[usize], None = nonexistent
container) was run through the standard filter and rejected on the
mission's own clause: With's ownership + init rules make a null
container unrepresentable in safe code, so an Option wrapper forces
every call site to unwrap a case the compiler already proved impossible
— unnecessary characters by definition. Zero of five reference projects
wrap length in Option.

Reference filter (verified in .reference/ checkouts): **signed** — Go
(`builtin.go:179, func len(v Type) int`; Go's own spec prose writes
`len(a)-1`), Swift (`Array.swift:821, var count: Int`), Vale
(`str.vale:24, HashSet.vale:84 — int`). **Unsigned** — Rust
(`vec/mod.rs:2931 usize`), Zig (`array_list.zig usize`). The split
falls exactly along declared values: the ergonomics-first languages
chose signed; the explicitness-philosophy languages chose unsigned and
knowingly accepted the trap. Vale is our designated ownership
reference; Rust is the explicit ergonomics anti-reference.

Mission filter: "built to remove the suffering" (the trap is a named
suffering); "safe as Rust" is a bar, not a compass — signed lengths
clear it with zero loss (overflow and bounds stay runtime-checked; no
real machine holds 2^63 elements, so the lost bit is free); "raw C
stays explicit; modeled C becomes humane" assigns -1-as-error to the
binding layer (the with_net -errno precedent), keeping it out of the
core types. The runtime already stored lengths as i64 (with_vec.len,
with_hashmap_len) — only the sema surface said usize.

### Scope / implementation

Signed applies to the whole length/count/index-of family, so the surface
stays consistent: `len()` and the collection len methods, iterator
`count()` (a length), and `position()`'s index (`Option[Int]`). **`size`
/ `align` type-layout methods stay `usize`** — those are memory-layout
constants for FFI, a different category, deliberately excluded.

Spec-ahead-of-implementation: §18.6 now says `Int`; the sema surface
(`SemaCheck.collection_len_method_return_type`, the `count`/`position`
/`capacity` sites, and lib/std BTree decls) still says `usize` until
**#630** lands the flip (the implementation vehicle). This is the normal
spec-leads-compiler posture — **do not "fix" §18.6 back to usize to match
the compiler; the compiler is what changes.** #630 carries a self-host
flip sweep (#629 protocol: length typing threads through the compiler's
own sources) and the full battery.

### What would reopen this

A concrete C-interop boundary where translating size_t at the modeled
layer is shown to be impossible or pervasively costly, or a real
program that needs > 2^62 elements.

---

## D10 — Channel termination: recv() -> Option[T]; None means closed and drained; Receiver is for-iterable

**Date:** 2026-07-16
**Status:** Accepted — BDFL ruling. **Deciders:** Eric (BDFL)

### The decision

`Receiver.recv()` returns `Option[T]`. Buffered messages are always
delivered first (`Some`); `None` means the channel is closed AND drained —
Rust's semantics in Swift's spelling. `Receiver` is directly for-iterable:
`for msg in rx:` receives until termination and falls out with zero
ceremony (desugars through recv's Option). CHAN_RECV codegen consumes the
runtime status (previously discarded — a closed-drained recv returned an
uninitialized value).

### Context / why

Closed-and-drained is the normal termination signal of every
producer/consumer pipeline, not an error. Panic (option A) converts
routine teardown into the error machinery and taxes the most common
channel idiom with try_recv/side-channel choreography — manufactured
suffering. A Go-style zero-value sentinel (option B) is silent wrong data
— the guardrail-removal the mission forbids — and is mechanically
unavailable anyway (With has no universal default for arbitrary T).
Option C prices honesty at one `?`/unwrap, which the language's own
happy-path doctrine already declared cheap, and the compiler proves every
consumer decided what shutdown means. Reference survey: Rust
(Result::Err after drain) and Swift (AsyncStream -> nil terminates
for-await) — the two memory-safe references — chose the type-honest
signal independently; Go's sentinel needed the `, ok` form and range
special-casing to patch; Zig and Vale ship no channels. The for-iterable
Receiver is the Swift lesson: termination-as-None makes iteration simply
end, deleting the loop's residual `Some` ceremony entirely.

Known residuals, deliberately left: `try_recv` remains specified-but-
unimplemented, and its `None` will conflate "empty now" with "closed" —
needs a three-state answer or documentation when implemented. Drop-bearing
payload ownership through the for-loop binding follows the current
provisional ownership state (#608 world).

Reopen if: channels grow a select-integrated recv arm whose binding shape
conflicts with Option (spec's select examples currently show both `msg =`
and `opt_msg =` spellings — reconcile when select-over-channels lands).

---

## D9 — E0921 concurrency evidence for async fns is usage-based (call/reference sites), not declaration-based

**Date:** 2026-07-15
**Status:** Accepted

### The decision

The global-data-race proof (§9.1) treats an `async fn` as concurrency
evidence at the sites where a fiber can actually come from it — direct
calls, generic calls, method calls (plain, generic, dyn-trait), and
references that coerce the fn to a callable value — not at the bare
declaration. Async blocks/scopes, `thread.spawn_os`, `@[c_export]`, and
extern-"C" callback coercions keep their existing evidence points
(`@[c_export]` stays declaration-based: presence *is* the external-caller
hazard).

### Context / why

`check_bodies` recorded evidence for every checked non-generic async fn
declaration. When #489 added `async fn task_cancel_point` to prelude-merged
`std.task`, every ZCU — including the compiler's own stage builds and every
user program with a mutable global — failed E0921 despite never creating a
fiber (offset-proven to lib/std/task.w:27 across the stage2 stderr). The
same defect already shipped: `use std.time` alone (uncalled `async fn
sleep`) poisoned any program with a mutable global. §9.1's obligation is
"the program *uses* no async construct"; its example labels a call site
("program creates fibers here"), and it explicitly classifies precision
improvements as compiler quality work, never a semantic change.

Alternatives weighed: exempting std-implementation decls from evidence
(unsound — `std.time.sleep(d)` called from user code creates concurrency
with zero user-side async decls); making `task_cancel_point` generic or
respelling the cancel edge (dodges the imprecision, leaves the prelude
landmine armed for the next non-generic async std fn).

Coverage was verified by matrix: uncalled decls (own and std) are clean;
direct/generic/method/dyn/fn-value routes, async blocks, and instantiated
combinator internals all still fail the proof. `test/compile_errors/
err_global_*` fixtures now call their async fn so the concurrency they
assert is real. Speculative overload probes (`generic_overload_match_score`)
never run call checking, so discarded candidates record no evidence.

Reopen if: a new fiber-creation route bypasses the hooked resolution
points (e.g. async fn values become spellable through paths other than
`check_ident`'s visible-sig coercion), or the runtime gains a way to start
fibers without any call/block/scope construct.

---

## D8 — Stores through raw pointers do not drop the old pointee

**Date:** 2026-07-12
**Status:** Accepted

### The decision

Assignment through a raw-pointer deref or index (`*p = v`, `p[i] = v` with
`p: *const T` / `*mut T`) is a **raw store**: the compiler does not emit
drop-before-overwrite for the old pointee. Replacing a live pointee is the
programmer's job in unsafe code: `let old = *p; drop(old)` then store.
Safe places — `var` bindings (§2.2), `&mut` derefs, fields — keep
drop-before-overwrite. A **field** store through a raw deref
(`(*p).f = v`) also keeps it: projecting a field asserts a live pointee,
so the old field value is provably live.

### Context / why

`Box.new`, `Rc.new`, `Mutex.new/set`, `RwLock.new/write`, and the
ScopedMut write-backs all store through raw pointers into memory that is
either freshly allocated (uninitialized) or already moved out. The niche
model's justification for drop-on-reassign (§2.5.1: every source is a live
value or a blanked one) does not hold there — fresh heap bytes are neither.
The emitted guarded drop then runs `Drop` on garbage whenever the allocator
returns non-zero recycled memory: observed as `State.drop` firing at
`box_ctx` time (spec_ss16_7) and `Mutex.set`/`RwLock.write` dropping the
replaced payload twice (spec_ss14_17_*, "oldold" traces). Every raw-store
site in the stdlib/runtime was audited: none relies on the old drop
semantics; `sync.w` already drops the old value explicitly before storing.

Alternative weighed: keep Rust's rule (`*p = v` drops; add a
`ptr::write`-style no-drop primitive). Rejected: it silently invokes drop
glue on memory the compiler cannot prove initialized (UB-by-default in the
common fresh-allocation case), contradicts every existing stdlib site, and
adds a primitive the mission says the programmer shouldn't need. "Raw C
stays explicit": a raw store stores.

Reopen if: With grows an initializedness proof for raw pointees, or a
`ptr::write`/`ptr::replace` surface makes the explicit-drop idiom obsolete.

---

## D7 — Eliminate `self`: the receiver mode is a `fn` prefix keyword; `self` and its type are never written (Swift-style)

**Date:** 2026-07-07
**Status:** Accepted — BDFL ruling. Plan: `docs/eliminate-self.md`. Spec: §2.4, §9.5. **Deciders:** Eric (BDFL)

### The decision

A method's receiver is expressed by a keyword on the declaration, not by a
parameter. `self` is never declared and its type is never spelled:

- `fn m()` inside `impl`/`extend`/`type` — instance, **read borrow** (`self: &Self`)
- `mut fn m()` inside a type — instance, **mutable share-place borrow** (`mut self: Self`)
- `move fn m()` inside a type — instance, **consuming** (`move self: Self`)
- top-level `fn Type.name()` — **associated**, no receiver (no `static` keyword)

**Instance vs. associated is decided by *location*, not a keyword:** inside an
`impl`/`extend`/`type` the receiver is synthesised; at top level there is none
(a `mut`/`move` prefix at top level is an error). This is Rust/Zig/Go's
presence-of-receiver rule with `self` implicit. `self` remains an implicit
binding in instance-method bodies; the receiver's type is always the enclosing
type. Implemented as a **parser desugar** to the existing (verified-working)
receiver-param shapes, so sema/MIR/codegen are unchanged.

**Trait declarations are the carve-out (part of the same ruling):** a trait
body must express both instance contracts and associated contracts
(`Default.default`, `Try.from_break`), and location cannot discriminate inside
the block. So in a `trait` body only the unambiguous keyword forms synthesise
(`mut fn` / `move fn`); a plain `fn` keeps today's explicit spelling — with a
receiver parameter it is an instance contract, without one it is associated.
Trait authoring is library-maintainer tier, so the residual ceremony lands on
the right audience. The end state for `lib/std/traits.w` is therefore: keyword
forms for mut/move/destructor contracts (`move fn drop()` is the only Drop
receiver, §2.4), explicit `self: &Self` on read instance contracts, plain
no-receiver `fn` for associated contracts. Do not re-open this by flipping
trait plain-`fn` to implicit-instance; that makes associated contracts
unspellable.

### Context / why

The mission's first law — *"every unnecessary character is a compiler failure;
if With can infer it, the programmer should not have to spell it out"* — applies
directly: a receiver's type is **always** the owner type, so `: Self` is pure
ceremony, and the mode is one bit that belongs on the declaration, not smeared
across a `self` parameter. The prior form `fn m(mut self: Self)` forced the user
to write the value (`self`), its mode, and its (inferable) type.

This ruling also **dissolves** four open issues instead of patching them: #646
(unflagged `self: ConcreteType` escapes the mode check — no annotation to
escape), #645 part 2 (`mut` discarded on a param — `mut` now only prefixes
`fn`), #644 (mut-self on a primitive owner — mode is uniform, type inferred),
and the bare-`mut self` codegen failure (bare receiver forms cease to exist at
the surface).

### Alternatives weighed

- **Keep `mut self: Self` (status quo).** Rejected: maximal ceremony; the spec
  even called it "canonical," contradicting the mission's first law. The clause
  is superseded here.
- **Bare `mut self` (drop only `: Self`, Rust shorthand).** Rejected as the
  end-state: still writes `self`. Eric's ruling: if `self` can be avoided, avoid
  it. (Bare `mut self` is nonetheless the internal desugar target's cousin — the
  desugar emits `mut self: Self` with a literal `Self` node.)
- **Swift `mutating`/`consuming` spelling.** Rejected the *words*: we reuse
  existing `mut`/`move` keywords (fewer characters, Rust-adjacent, no new
  reserved words).

### Reference consensus

Swift is the model: `SelfAccessKind` (`include/swift/AST/Decl.h:262` —
`NonMutating`/`Mutating`/`Consuming`/`Borrowing`) is a **decl** property and
`self` is a compiler-synthesised `getImplicitSelfDecl()`. `mutating ⇒ inout
self` (OwnershipManifesto) is verbatim With's share-place (D5). Swift threads a
persisted `SelfAccessKind`; we take a cheaper route (parser desugar to shapes
sema already handles). Rust's `&self`/`&mut self`/`self` shorthand and Swift's
implicit `self` both confirm "no receiver type annotation" as the ergonomic
norm; Go/Zig write the receiver type and are explicitly the more-ceremony pole
we reject.

### What would reopen it

Evidence that implicit `self` cannot express a needed method shape (verified by
running, not reasoning), or that the location discriminator (inside a type vs.
top level) creates an ambiguity the desugar cannot resolve. Supersedes the §2.4
"canonical receiver is `move self: Self`" wording (now `move fn drop()`).

---

## D6 — `FnAbi` is the single ABI source of truth: compute once, both sides read it, never re-derive per call path

**Date:** 2026-07-06
**Status:** Accepted — CANONICAL standard for all call-ABI lowering
**Design:** `docs/fn_abi_descriptor_design.md` · **Deciders:** Eric (BDFL)

### The standard

Every function signature has ONE ABI descriptor — `FnAbi { args: [ArgAbi], ret,
sret }`, where `ArgAbi = { pass: PassMode, llvm_ty }` and
`PassMode = Direct | Indirect | IndirectPlace | Fat | Ignore`. It is computed
ONCE by `compute_fn_abi(sig)` (cached per sig) and is the **single source of
truth** for both the callee prologue (`declare_function`) and every call site
(`push_call_arg`). No code may re-derive "how is this argument passed" from the
type or context on its own — it reads the descriptor.

`PassMode` meanings: `Direct` = by value (Copy/scalar); `Indirect` = pointer to a
callee-owned copy (byval); `IndirectPlace` = pointer to the CALLER's place
(share-place — callee mutates the caller's data and does NOT drop it); `Fat` =
dyn-trait fat pointer; `Ignore` = zero-sized.

### Why (the reference consensus)

Every serious compiler does exactly this and only this: Rust `FnAbi`/`PassMode`
(`fn_abi_of_instance`, read by caller + prologue + return), Go
`ABIParamResultInfo` (`ABIAnalyzeFuncType`), Zig `fn_info` classification,
Clang/LLVM `CGFunctionInfo`/`ABIArgInfo` (read by `EmitFunctionProlog` +
`EmitCall`). The single descriptor makes caller/callee/path divergence
**impossible by construction**. With historically lacked it — it re-derived the
ABI per call path (`value_ref_abi`, `internal_abi_needs_indirect_param`, byval
masks, `fn_ref_param_*`, sret flags, all separate and recomputed), and the paths
drifted. The transparent `Box`/`Rc`/`Arc` receiver bug (`T*` on the concrete
path, `T**` on the generic path, both "working") is the textbook symptom.

### Protection / the rule going forward

- **All call-ABI classification flows through `compute_fn_abi`.** Adding a new
  call-lowering path, a new receiver shape, or a new parameter kind means
  extending `PassMode`/`compute_fn_abi` in ONE place, then reading it — never
  writing a fresh per-path "value vs address vs byval" decision.
- The scattered predecessors (`value_ref_abi`, per-path
  `internal_abi_needs_indirect_param`, byval masks, `fn_ref_param_*`) are being
  consolidated into `FnAbi`; after consolidation, re-introducing a per-path ABI
  derivation is a regression.
- Share-place (D5) is `PassMode::IndirectPlace`, driven by the effect (P0). The
  callee-no-drop and the caller-address-passing are consistent because they read
  the same `ArgAbi` — this is *why* the descriptor is the right home for it.

### Consequences (the rewire)

Build `FnAbi`/`ArgAbi`/`PassMode` + `compute_fn_abi(sig)` (behavior-neutral —
reproduce today's classifications, resolving the transparent divergence to one
form) → route `declare_function` + one `push_call_arg` through it (the cathedral,
descriptor-driven; the transparent bug fixed by unification) → flip
`IndirectPlace` on for share-place. The landed `mir_ref_arg_ptr` brick is the
`IndirectPlace` marshalling arm.

---

## D5 — The calling convention is SHARE-PLACE by default (restore mutability.md); do not revert to move

**Date:** 2026-07-05
**Status:** Accepted — CANONICAL, load-bearing, protected
**Spec:** `docs/completed/mutability.md` (authoritative) · **Deciders:** Eric (BDFL, original author of the design)

### Decision

With's calling convention for a non-`Copy` value passed `f(x)` is an **ephemeral
shared-place alias**: the callee operates on the **caller's** place (reads and
mutations are caller-visible), the caller retains ownership, and the destructor
runs in the caller's scope. `move`/`copy` at the call site are required **only**
when the callee's inferred effect summary on that parameter is `consume` or
`escape_value`; `escape_view` is governed by view-origin lifetime tracking. This
is the full model in `docs/completed/mutability.md` (effect summaries, the
Copy/non-Copy split, receiver modes `&self`/`mut self`/`move self`, `&T` niche,
`@[effect(...)]` pinning). It is authoritative.

### Why (Eric, verbatim intent)

"mutability.md's shared-place design was my explicit design and will, and yes it
was unique to With — a calling card, a statement of what With means. Subsequent
agents have trampled it." The share-place default is the anti-ceremony mission
made concrete: `bump(p)` mutates `p` with no `&mut` tax — Python-shaped
ergonomics with static, borrow-checked safety. No systems reference does this
(Vale/Rust move; Zig/Go copy); Python is the only prior art, and With makes it
statically safe. This is the point of With.

### The regression being corrected

The implementation drifted to **move + callee-drop**: by-value non-`Copy` params
are treated as consumed and dropped by the callee (`lower_fn_with_sig` schedules
a value-drop for every non-Copy param; #605 treats a moved-in value as consumed;
argument lowering `OK_MOVE`s non-Copy args). That is Rust/Vale semantics, not
With's. It was a silent agent "simplification," and it is wrong.

### Protection (this is the point of writing it down)

- **Do not revert to move-by-default.** If a future agent finds by-value non-Copy
  params being moved/consumed/callee-dropped by default, that is the bug to fix
  toward share-place — never a behavior to preserve, extend, or re-introduce.
- **Do not propose move-by-default or copy-by-default** as a "simplification,"
  performance win, or Vale/Rust-alignment. The mission's "as safe as Rust" is a
  safety bar; share-place meets it via effect summaries + borrow checking without
  adopting Rust's move-by-default.
- Before touching parameter passing, argument/call lowering, drop scheduling, or
  effect inference, re-read `mutability.md` in full and preserve share-place.
- CLAUDE.md "Language Design Philosophy" carries the standing guardrail.

### Consequences (the implementation work)

Restore the model end to end: infer per-parameter effect summaries
(read/write/consume/escape_value/escape_view) from bodies; make the default
non-Copy call a share-place borrow (pass a reference to the caller's place, no
callee-drop, destructor in the caller's scope); require `move`/`copy` only for
consume/escape_value; keep escape_view under view-origin tracking; the borrow
checker enforces aliasing conflicts via effect summaries. Receiver modes and the
`Copy` opt-in are already aligned (Cycle 1). Deferred follow-ons (the other
receiver/param calls, queued bug fixes) are in
`docs/resume_after_mutability_fixed.md`.

---

## D4 — #602: `retains:` c_import contract, enforced check-time via cstr_in modeling

**Date:** 2026-07-05
**Status:** Accepted
**Issue:** #602 · **Spec:** §16.3c · **Deciders:** Eric (BDFL)

### Decision

A c_import param can be annotated `retains: ["fn(idx)"]` — the callee keeps the
passed C-string pointer past the call. Such a param is a **modeled** C-string
input (`cstr_in`: callable without `unsafe`, a pointer into caller-owned storage
is accepted), but a call-scoped `str` temporary is **rejected** at check time
with guidance to pass `to_cstring()?.as_cstr().ptr()`. Params are borrowed by
default; only `retains:` marks retention.

### Why this shape (the "unreachable" detour)

A first pass built the store + enforcement but found it *unreachable*: the
`str→*const c_char` coercion only fires for `cstr_in`-modeled functions, and
`cstr_in` modeling came exclusively from the hardcoded `ci_overlay_cstr_in_param_count`
list — all borrowed, none retaining, not user-extensible. The fix was NOT to
defer but to make the finding the design: **`retains:` itself is the cstr_in
evidence.** A retained `const char*` param becomes a modeled cstr_in param (so
`ci_function_requires_raw_abi` no longer marks it raw) whose retention is
enforced at the coercion site (SemaCheck) — rejecting the `str`, accepting an
owned pointer. This makes the whole feature reachable and testable with pure
user code, no dependency on a real retaining libc function.

### Reasoning

- **Go cgo** documents a pointer-retention contract and enforces it dynamically
  under `cgocheck`; **We** enforce it statically at the coercion boundary
  (compile-time, zero runtime cost) with the `dbg_scribble` debug allocator as
  optional runtime teeth. Adopted the contract-with-teeth idea; rejected Rust's
  docs-only unsafe (no guardrail) and Zig's fully-manual approach.
- Mission "modeled C becomes humane, with guardrails": the annotated surface
  stays zero-ceremony for the borrowed common case; the guardrail appears only
  when a param actually retains.

### Consequences

- Sema `retained_extern_params` (name_sym → retained-param bitmask), populated by
  a reader over c_import `retains:` records.
- `ci_function_requires_raw_abi` treats a retained const-c-string param as a
  modeled cstr_in param.
- Enforcement at the SemaCheck c-char coercion site.
- The curated overlay is the `retains:` clause itself (user-extensible); a real
  retaining libc function can be seeded there if one is identified.

---

## D3 — Friendly aliases are shadowable; `Unit`/`Never` stay reserved (split of option D)

**Date:** 2026-07-05
**Status:** Accepted
**Issue:** #627 (substrate) · **Spec:** §4.1, §29.8 · **Deciders:** Eric (BDFL)

### Decision

The friendly convenience aliases `Int`, `UInt`, `String`, `StrView`, `CStr`
become prelude-scoped, user-shadowable names: a `type` declaration of the same
name in a user module wins over the builtin alias. The core primitives
(`i8`…`u128`, `f32`/`f64`, `bool`, `str`, `usize`, `isize`) **and** `Unit` and
`Never` stay compiler-reserved (not shadowable).

The original option-D ruling (2026-07-04) demoted all seven friendly names
*including* `Unit`/`Never`. Scoping revealed `Unit` has ~331 uses across the
compiler sources (`Never` ~15) — it is a core type in every `-> Unit`
signature, not a convenience alias — and `Unit`/`Never` are not cleanly
spellable as an alias RHS (no `()`/`!` type syntax). Demoting them is a
high self-host-flip-risk change out of proportion to any benefit, so they are
excluded. Eric ruled for the split.

### Implementation note

Shadowing was already *almost* free: `register_prim` records these names as
empty-path (prelude-tier) entries, and `lookup_named_type_visible` returns a
visible user declaration before the empty-path fallback. The only thing forcing
the builtin was four resolution-first hardcodes in `primitive_type_by_sym`
(SemaDecl.w) for `Int`/`UInt`/`String`/`StrView` — dead when unshadowed (the
named-types path returns first), fired only to override a user shadow. Removing
those four lines enables shadowing with zero self-host impact (the compiler
never shadows these; unshadowed resolution is byte-identical). `CStr` was
already a plain named struct, not resolution-first. This also unblocked the
`StrView`-collision that obstructed probing #625/#626.

### Reasoning

Matches Go's universe-block predeclared identifiers and Rust's prelude — both
shadowable — while keeping the truly foundational names reserved (Zig-style)
where user override would be a footgun with no upside. "Don't make the user
write ceremony / don't block a safe user choice" (mission) argues for
shadowable conveniences; "never risk the self-host build for a cosmetic win"
argues for keeping `Unit`/`Never` reserved.

---

## D2 — #625: containers of ephemerals use a viral-ESCAPE model, not an annotation ban

**Date:** 2026-07-04
**Status:** Accepted (supersedes the "ban outright" framing of the D-day
soundness ruling and the §5.2 narrowing in commit 6f9160e3)
**Issue:** #625 · **Spec:** §5.1, §5.2 · **Deciders:** Eric (BDFL), informed by
reference-implementation review

### Decision

A heap container whose element type is ephemeral (`Vec[View]`, `Box[View]`,
`HashMap[K, View]`, …) is **itself ephemeral** and is **allowed** as a local or
a by-value parameter. What is rejected is the **escape**: returning it where the
return type is not ephemeral, storing it in a heap container or a non-ephemeral
struct field, or boxing it. This is enforced by **borrow-origin tracking** —
storing an element into a container propagates the element's stack view-origins
onto the container binding, so the existing ephemeral-escape checks fire on a
later return/store — **not** by banning the container type at its annotation.

### Context / how we got here

The first implementation (this cycle) followed the literal "ban outright"
ruling: reject an ephemeral element type at every annotation, push, and literal
site. It built and fixpointed, but broke two capability tests because the stdlib
itself uses `parallel(workspaces: Vec[Workspace])` (build.w:627) — the *only*
container-of-ephemeral in the whole stdlib.

Investigating that failure surfaced three facts that reframed the ruling:

1. **`ephemeral` is used here overwhelmingly as a linearity/capability marker,
   not a borrow marker.** All 28 ephemeral stdlib types (every iterator, lock
   guard, `Workspace`, `Context`, task/join handles) have all-owned or
   raw-pointer fields; none has a `&`/slice field.
2. **The compiler cannot structurally tell a dangling ephemeral from a safe
   one.** `StrView = ephemeral { ptr: *const u8, len }` (the exact freed-memory
   type in #625) and `Workspace = ephemeral { token: str, id }` are structurally
   identical — both raw-pointer/owned fields. A refinement that banned only
   `&`/slice-containing types would let the actual bug type slip through
   (verified).
3. **`str` is owned** (spec §), so `Workspace{token: str}` carries no live stack
   view-origin. The origin-tracking machinery therefore *already* distinguishes
   `Vec[Workspace]` (no origin → safe to return) from `Vec[View]` (borrows
   `&local` → escape caught) — the distinction is "does the value carry a live
   stack view-origin," exactly Rust's lifetime model.

### Alternatives weighed

- **A — viral-escape (chosen).** Allow the container; catch the escape via
  origin tracking. Fixes the `return Vec[StrView]` freed-memory bug; keeps
  `parallel(Vec[Workspace])` working; needs origin propagation through
  container stores (the bounded new work).
- **B — blanket annotation ban (the first impl).** Simplest, strictest. Bans
  memory-*safe* batching; forces refactoring `parallel()` and forbids any future
  batch API of linear handles. Rejected: bans safe code and reads as "safe by
  ceremony," which the mission forbids.
- **C — blanket ban + opt-in `@[storable]`.** Adds a type-author attribute to
  exempt safe markers. Rejected: leaks the borrow-vs-linear distinction into a
  type author's vocabulary for no safety gain.

### Reasoning

- **Reference review was unanimous** (Eric asked for it before ruling). Every
  reference language that *has* the concept allows the container and controls
  the escape, none bans the annotation:
  - **Rust:** `Vec<&str>` / `Vec<&[&str]>` are normal types (in the stdlib
    docs); the lifetime parameter bounds the container and the errors are all
    escape errors (E0515 return-ref-to-local, E0521 borrow-escapes, E0716
    temp-dropped-while-borrowed). This *is* the viral-escape model.
  - **Vale** (our ownership design compass): containers of region refs are
    allowed; **regions** (static) + **generational references** (runtime)
    control escape — never an annotation ban.
  - **Zig:** `ArrayList(*T)` allowed; dangling is UB, the programmer's job.
  - **Go:** GC + escape analysis; no borrow concept — n/a.
- **Mission fit.** "Exactly as safe as Rust" is a *bar*; here we can meet it with
  Rust's *own* model. Banning `Vec[Workspace]` — which is memory-safe — is
  "ceremony for something that doesn't matter," which the mission explicitly
  forbids. Vale, the design compass, points the same way.
- **The issue author's own suggested model was escape-based** ("locals fine,
  stores rejected, returns propagate"), not annotation-based.

### Consequences

- §5.2 restored to full virality ("any generic `F[T]` is ephemeral"), enforced
  at the escape rather than the annotation — reverting the 6f9160e3 narrowing.
- Origin tracking extended: a container store (`push`/`insert` on a local)
  unions the element's view-origins onto the container binding
  (`add_binding_view_deps`); container literals recurse their elements in
  `collect_expr_view_deps`.
- `Vec[Workspace]` and friends compile; `return`/store/box of a container that
  borrows a stack local is a compile error.
- The "safe by construction beats viral tracking" note added to §5.2 in
  6f9160e3 is withdrawn: the reference review showed viral tracking is the
  standard and the construction ban was unsound-adjacent (false negatives on
  raw-pointer ephemerals, false positives on owned-field markers).

---
