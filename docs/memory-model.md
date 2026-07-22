# The Four Disciplines — memory-model framing note

Status: adopted as a framing note (BDFL, 2026-07-21). Restructuring §1.4 of
the specification around this taxonomy is deliberately deferred until the
Sema-split campaign has stress-tested it: if "is this monotone or linear?"
turns out to be the question that resolves that campaign's design forks, the
framing earns the spine position; if state keeps appearing that fits none of
the four boxes, better to learn it here than in the spec.

With's memory story is a **sum of four simple disciplines**, each with a
small, independent soundness argument — rather than one unified borrow
calculus. Each proof is small; the seams are where the rules live. This is
"with-y, not rust-y" made precise, and it is the sense in which the language
is mathematically tractable: four separately checkable regimes instead of a
monolith.

## The disciplines

1. **Linear — owned values.** Exactly one owner; transfer by move.
   Soundness: reset-on-move (§2.5) — a move blanks its source and a blanked
   drop is a no-op, so exactly-once holds at runtime even where the static
   analysis is blind. The analysis is a diagnostic and an optimizer, never
   the guarantee.
2. **Ephemeral — borrows and views.** Call- and scope-bound access (§3, §5).
   Soundness: escape is a *property the checker rejects* — no storage means
   no dangling; nothing needs tracking because nothing outlives its origin.
3. **Generational — handles.** Long-lived, non-owning relationships as typed
   indices into pools (§6). Soundness: validity is a checked runtime fact —
   a per-slot generation turns use-after-remove into `None`.
4. **Monotone — contexts.** Append-only state behind a Copy pointer-handle
   (`InternPool`, `AstPool` today). Soundness: grow-only state is a
   join-semilattice — every aliased reader observes a consistent view, which
   is why sharing these handles has never produced a bug. Three conditions,
   all required:
   - **Declared monotone API** — append/read-only over pointer-stable
     storage. Declared, not proven (v1): a trusted, library-maintainer-tier
     assertion, loud and auditable, like a modeled C binding.
   - **Containment** — the pool must outlive every handle. Discharged either
     by *ephemerality* (the handle is obtained via scoped access and never
     stored) or by *program-lifetime pools* (the `InternPool` status quo).
     A **storable** Copy handle is sound only under the program-lifetime
     discharge — rustc buys the storable case with `'tcx`, the exact
     ceremony With deletes.
   - **Concurrency scope** — the semilattice argument is single-fibered.
     Appends must be confined to one fiber per phase, or synchronized.

## Seam rules

- **Linear across a phase boundary: take-and-return.** The receiving phase
  owns the value; every exit path hands it back; the source binding is blank
  (reset-on-move) in between. Reconciling two copies after the fact
  ("re-sync") is aliasing wearing a costume and is forbidden. Precedent:
  `lower_module` (Compilation.w); the Backend follows the same pattern.
- **Consuming a field of a linear value reached through a borrow** blanks
  the field and *writes* the root (D17) — never promotion to consuming the
  whole root. Copy-typed projections keep the promotion: escaping a copied
  pointer field captures the root's content by aliasing, and nothing is
  blanked.
- **`move` is rvalue-uniform and callee-independent** (D16): after
  `f(move x)` the binding is invalid and the value is destroyed or
  transferred by the end of the statement, whatever the callee's inferred
  effects.
- **A monotone handle inside a linear value** (the pools inside `Sema`) is
  ordinary: the handle is just a Copy value; the discipline lives in the
  context type's API, not at the use site.

## Open question (BDFL, after the Sema split)

Whether **monotone is a peer discipline or a library-tier pattern** built on
the other three — a Copy handle is just a value, the pool is just owned, and
the discipline is an API restriction. Current lean: peer, because the
soundness argument (semilattice) is genuinely distinct from the other three.
The context-type paragraph for the specification proper — carrying the three
conditions above — lands with the Sema-split campaign, not before.
