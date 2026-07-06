# Decision Log

Architecture/design decisions and *why* we made them. Newest first. Each entry
records the decision, the context, the alternatives weighed, and the reasoning —
so a future maintainer (or agent) does not re-litigate a settled call, and can
tell whether a later fact should reopen it.

Format per entry: a short ID + title, date, status, and the reasoning. When a
decision supersedes an earlier one, say so in both.

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
