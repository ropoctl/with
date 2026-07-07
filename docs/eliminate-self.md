# Eliminate `self`: Swift-style implicit receiver

**BDFL ruling (Eric, 2026-07-07):** the receiver `self` and its type
annotation are **unnecessary characters** and must not be written. The
receiver mode becomes a prefix keyword on the function declaration
(`mut fn` / `move fn` / plain `fn` / `static fn`); `self` is implicit in the
body; the receiver's type is always the enclosing type and is never spelled.
This is Swift's `mutating`/`consuming`/`borrowing func` model, adapted to With's
existing `mut`/`move` keywords.

This document is the implementation plan. The normative surface is amended in
`docs/with-specification.md` (§2.4, §9.5); the rationale is recorded in
`docs/decisions.md` (D7).

---

## 1. The design

### Canonical surface (target)

```with
impl Counter:
    static fn new(n: i32) -> Counter:      # static: no receiver
        Counter { n: n }
    fn get() -> i32:                        # instance, read borrow  (implicit `self: &Self`)
        self.n
    mut fn bump():                          # instance, mutable borrow (implicit `mut self: Self`)
        self.n = self.n + 1
    move fn into_n() -> i32:                # instance, consuming      (implicit `move self: Self`)
        self.n

impl Drop for File:
    move fn drop():                         # the only destructor receiver mode (§2.4)
        close_file(self.fd)
```

- **`self` is never declared.** It is an implicit binding available in the
  body of every instance method (exactly like Swift's `getImplicitSelfDecl()`).
- **The receiver's type is never spelled.** It is always the enclosing type
  (`Self`).
- **The mode is the keyword on `fn`:**
  | keyword | receiver semantics | desugars to |
  |---|---|---|
  | `fn` (in impl / `Type.`) | read borrow | `self: &Self` |
  | `mut fn` | mutable share-place borrow | `mut self: Self` |
  | `move fn` | consuming (owns `self`) | `move self: Self` |
  | `static fn` | no receiver | *(no self param)* |

### Why this maps cleanly onto our model

Swift stores the receiver mode as a `SelfAccessKind`
(`include/swift/AST/Decl.h:262`: `NonMutating` / `Mutating` / `Consuming` /
`Borrowing`) on the function decl, and synthesises the `self` `ParamDecl` in the
compiler — the user writes neither the parameter nor its type. Our advantage:
we already have working, verified lowering for the three explicit receiver
shapes (`self: &Self`, `mut self: Self`, `move self: Self`). So we do **not**
need to thread a new `SelfAccessKind` through sema/MIR/codegen the way Swift
does. **We desugar in the parser to the existing shapes**, and everything
downstream is unchanged.

`mut fn` = "`self` is passed `inout`" is precisely With's share-place mutable
borrow (caller keeps ownership, callee mutates the caller's place). Swift's own
rationale for `mutating = inout self` (OwnershipManifesto: the caller retains
the storage, the borrow is statically checkable) is verbatim our share-place
rationale (D5) — so this is the same ownership model with less ceremony, not a
new one.

### What this dissolves (not patches)

- **#646** (unflagged `self: ConcreteType` escapes the mode check) — there is no
  `self` parameter to annotate, so nothing escapes. The mode is the keyword.
- **#645 part 2** (`mut` silently discarded on a non-self param) — already
  fixed by rejecting it; `mut` now only ever appears as `mut fn`.
- **#644** (mut-self on a primitive owner) — the mode is uniform across owner
  kinds; the owner type is inferred whether struct or primitive; the by-pointer
  ABI question is answered once at the desugar (a `mut fn` receiver is always
  `mut self: Self`).
- **bare-`mut self` codegen failure** — bare receiver forms stop existing at the
  surface; the desugar only ever emits the verified-working annotated shapes.

---

## 2. Feasibility (verified, not assumed)

1. **Owner known at parse time.**
   - `impl` form: `parse_impl_block` holds `type_name` (`src/Parser.w:3023`).
   - `fn Type.method` form: the owner `type_str` is in hand at
     `src/Parser.w:1179`, *before* the parameter list is parsed
     (`src/Parser.w:1187`).
2. **Synthesis precedent.** The parser already synthesises declarations and
   params: `synthesize_implicit_main` (`:237`), `queue_synthetic_copy_impl`
   (`:1550`), synthetic parameter patterns (`:7565`), synthetic type nodes
   (`:2067`). Injecting a synthetic receiver param is the same machinery.
3. **Downstream is unchanged.** Confirmed working end-to-end today:
   `fn m(self: &Self)` (read) → runs; `fn m(mut self: Self)` (mut) → mutates;
   `fn m(move self: Self)` (move) → consumes. The desugar targets exactly these.
4. **Mode/method machinery exists.** `SemaDecl.w:1277` already enforces "a
   method receiver requires an explicit mode"; that enforcement moves upstream
   of the desugar.

**Verdict: front-end-only change riding on paths that already work. No new
codegen.**

---

## 3. The one genuinely new concept: instance vs. static

Today the *presence of a `self` parameter* is what distinguishes an instance
method from a static function in an `impl`. Once `self` is implicit, we need a
new discriminator. Swift's answer (adopted): a plain `fn` inside an `impl` /
`Type.` is an **instance** method (implicit read-borrow `self`); a **static**
function is marked `static fn`.

This is the only part that touches existing code meaning: every current static
`impl` function that has no `self` parameter (`Type.new`, `Type.from_*`, factory
and free helpers under an `impl`) must gain `static fn`. This migration must
land **before** the plain-`fn`-is-instance flip, otherwise a bare `fn new()`
is ambiguous between "old static" and "new instance read-borrow".

---

## 4. Implementation phases

Each phase self-hosts and passes the full gate
(`with build && :fixpoint && :test`) before the next. Because phases 1–3 change
**parser semantics**, each requires the self-host flip sweep (see memory
`project_629_selfhost_flips`): instrument old-vs-new decisions, build stage1,
diff the tree, review every flip before gating. Until the campaign-end seed
update, compiler sources must not rely on the new spelling.

### Phase 0 — Grammar: accept the modifiers (no semantics)
- Parser: accept `mut` / `move` / `static` as a prefix before `fn` in
  declaration position (both `impl` bodies and top-level `fn Type.method`).
- Store the modifier on the fn node (a new `FN_FLAG_RECV_MUT` /
  `FN_FLAG_RECV_MOVE` / `FN_FLAG_STATIC`, or reuse the existing self-param flag
  space). No desugar yet — just parse + carry, error if a modifier appears on a
  non-method `fn`. Gate green (pure addition, no existing code affected).

### Phase 1 — Desugar `mut fn` / `move fn` (unambiguous)
- When a method decl carries `FN_FLAG_RECV_MUT` / `_MOVE`, the parser
  **prepends a synthetic receiver param** to the parameter list:
  `mut self: Self` / `move self: Self` — a real `self` name node + a literal
  `Self` `NK_TYPE_NAMED` node (the mode machinery keys off the literal `Self`;
  see #646). Downstream is untouched.
- This is **safe and unambiguous**: `mut fn` / `move fn` have no prior meaning,
  so nothing existing conflicts.
- Migrate the compiler + stdlib `mut self: Self` / `move self: Self` methods to
  `mut fn` / `move fn` (drop the explicit receiver). Mechanical; the emitted AST
  is identical, so behavior is unchanged (the gate proves it). This also
  migrates `impl Drop: fn drop(move self: Self)` → `move fn drop()`.
- Keep the explicit `mut self: Self` / `move self: Self` forms **accepted** so
  migration can be incremental.

### Phase 2 — `static fn` + migrate static functions
- Parser: `static fn` on an `impl` / `Type.` function marks it static
  (synthesise no receiver). A top-level `fn foo()` outside any impl is a free
  function and is unaffected.
- Migrate every existing no-`self` `impl` / `Type.` function to `static fn`
  (`Type.new`, `Type.from_*`, factories). This is the enabling migration for
  Phase 3. Sweep the whole tree; the gate + fixpoint prove nothing was missed
  (an un-migrated static function would flip to an instance method in Phase 3
  and fail to type-check).

### Phase 3 — Flip plain `fn` to instance read-borrow
- After Phase 2, a plain `fn` inside `impl` / `Type.` with no explicit receiver
  desugars to `fn m(self: &Self, …)` (implicit read borrow).
- Migrate read-borrow methods (`fn get(self: &Self)` → `fn get()`), dropping the
  explicit receiver.
- A method that uses no `self` is still an instance method (Swift parity); mark
  it `static fn` if it should be static.

### Phase 4 — Retire explicit-`self` receivers
- Reject an explicit `self` parameter (`self:` / `mut self:` / `move self:` /
  `&self`) with a fix-it pointing at the modifier form. "Nonexistence of `self`"
  is now enforced.
- Update all remaining spec examples and `examples/` to the self-less form.
- Campaign-end bootstrap: one chain
  `:test → :last-green → :update-seed → :install-user`; verify the new seed
  compiles a self-less probe.

---

## 5. Edge cases to design/verify per phase

- **`Self` type node synthesis** — the synthetic receiver must carry a literal
  `Self` (mut/move) or `&Self` (read) type node, not the concrete owner name
  (`self: ConcreteType` is the #646 bug path). Verify the synthesized node
  routes through the working receiver-mode classification.
- **`fn Type.method` free-function form** — owner is `type_str`
  (`Parser.w:1179`); synthesise the same receiver as the `impl` form.
- **Generics** — `mut fn bump[T]()` on a generic owner: `Self` resolves to the
  generic instance, as it does for explicit `mut self: Self` today
  (`behav_mut_self_drop_generic` is the guard test).
- **Trait / interface methods without a body** — the modifier must be parseable
  on a signature-only method declaration and flow into the trait's expected
  receiver shape.
- **`move fn drop()`** — the only Drop::drop receiver (§2.4); the #642 check
  ("Drop.drop must consume") moves to "Drop.drop must be `move fn`".
- **Explicit `self` uses in the body** — `self`, `self.field`, and passing
  `self` onward (`f(self)`) must resolve against the synthesized binding
  exactly as against a written `self` param today.
- **`static fn` calling convention** — a `static fn` is an ordinary function
  namespaced under the type; no receiver ABI. Verify call-site resolution
  (`Type.method()` static call vs `value.method()` instance call).
- **One-line assignment-body methods** — noted during design: a one-line
  `fn m(...): self.x = e` shape has a separate codegen quirk; ensure the desugar
  does not depend on body shape.

---

## 6. Verification per phase

- Fast check (`out/stage/bin/with-stage2 check src/main.w`) before any build.
- Probe each edge case above with `out/release/bin/with` (never the seed).
- Fixtures: `behav_*` for each mode (read/mut/move/static) in both `impl` and
  `Type.` forms, generics, trait methods; `compile_errors/` for a modifier on a
  free function, a static call on an instance method, and (Phase 4) an explicit
  `self` parameter.
- Full gate + fixpoint. Fixpoint is the self-host regression proof for the
  parser change.
- `/drop-audit` before/after Phase 1 and 3 (receiver-mode drop discipline).

---

## 7. Reference inspiration (Swift, `.reference/swift`)

- `include/swift/AST/Decl.h:262` `enum class SelfAccessKind` — the receiver mode
  is a decl property (`NonMutating`/`Mutating`/`Consuming`/`Borrowing`), not a
  parameter. Our `fn`/`mut fn`/`move fn` map to `NonMutating`/`Mutating`/
  `Consuming`; we encode it by desugar rather than as a persisted enum.
- `getImplicitSelfDecl()` (AST) — `self` is a compiler-synthesised `ParamDecl`,
  never user-written. Our parser synthesises the receiver param.
- `docs/OwnershipManifesto.md` — `mutating` ⇒ `inout self`, statically checkable
  because the caller retains the storage. This is With's share-place (D5).
- SE-0377 `consuming`/`borrowing` — Swift's later split of ownership on the
  receiver; our `move fn` is `consuming`, plain `fn` is `borrowing`.
