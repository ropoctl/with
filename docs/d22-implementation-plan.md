# D22 Implementation Plan — Uniform Keyed Lookup, Contextual Copy, and View Origins

**Status (2026-07-23): Implementation in progress.**

## Authority and scope

[`docs/d22-Eric-Ruling.md`](d22-Eric-Ruling.md) is the canonical and complete
D22 ruling. Specification v7.2 must conform to it. This plan is only an ordered
implementation checklist: it must not narrow, reinterpret, or add semantics to
the ruling. If this plan conflicts with the ruling, the ruling wins and this
plan must be corrected before implementation continues.

D22 applies to every owning keyed map. The currently named implementations are
`HashMap[K, V]` and `BTreeMap[K, V]`; it also confirms the existing
`SlotMap[T]` lookup/removal contract. D22 does not restandardize the signatures
of Vec, fixed-array, slice, string, iterator, or arbitrary user-defined lookup
APIs. Those APIs participate in D22's general expression and origin rules
according to their existing signatures. Changing those signatures is a
separate D23 candidate.

D22 does not change a map's key-parameter mode. It also does not authorize an
unrelated source-signature, bootstrap, string-runtime, or general parameter-ABI
migration. Keep such work in a separate plan and batch.

## Non-negotiable semantic core

- Every owning keyed-map lookup observes map-owned storage:
  `get(...) -> Option[&V]` for every `V`.
- Removal transfers ownership: `remove(...) -> Option[V]`.
- A map lookup view originates only in the receiver, never in the transient
  key.
- A shared `&T` remains `&T` through inference, forwarding, structural
  projection, capture, and exact-payload elimination, including when `T: Copy`.
- An independently established owned-value demand may materialize `&T` only
  when `T: Copy`: copy the pointee first, then apply ordinary value coercions.
- Contextual Copy never clones, allocates, transfers ownership, duplicates a
  `Drop` value, selects an overload or method, changes dispatch, or changes ABI.
- Patterns are structural projections, not owned-demand positions. Nested
  projection through `&T` produces shared subviews and preserves reference
  layers exactly.
- Multi-expression joins use one arm-order-independent algorithm. Exact-equal
  arms preserve their type; non-reference expressions or an enclosing expected
  type may establish an owned result; compatible `&Copy` arms then materialize.
  A reference-only join preserves references and unions origins. Owned
  temporaries are never implicitly borrowed to force a reference result.
- Diverging `return`, `break`, and `continue` fallbacks contribute no result
  type. Removing the last owned anchor may change an inferred join back to a
  reference; an explicit expected type pins the intended result.
- Origins follow semantic values through transparent carriers and every
  semantic engine. Wrapper spelling, compiler temporaries, IR, inlining, and
  backend representation never launder a view.
- Only a real ownership boundary ends an origin for the independent result:
  contextual Copy, `copied`, `clone`, `cloned`, construction of an independent
  owned value, `remove`, or another explicitly consuming ownership transfer.
- `Option[&T].copied() -> Option[T]` requires `T: Copy`.
- `Option[&T].cloned() -> Option[T]` requires `T: Clone`.
- Raw pointers never participate in contextual Copy.

## Implementation sequence

### 1. Version the complete conformance matrix

Keep failing D22 fixtures explicitly marked NON-COMPLIANT until their required
verdict is implemented. Do not weaken a fixture to match current behavior.
Before moving any fixture into an active lane, verify its exact type, origin,
ownership, diagnostic, and runtime/drop behavior as applicable.

The matrix must cover all of the following.

#### Uniform producer and eliminator types

- `HashMap.get` and `BTreeMap.get` produce `Option[&V]` for Copy and non-Copy
  values.
- `SlotMap.get` remains `Option[&T]`.
- `remove` produces owned `Option[V]`/`Option[T]`.
- Unannotated `get(...).unwrap()` and `expect(...)` infer `&V`.
- Built-in `?` and user-defined `Try` preserve the exact success payload.
- `Some(value)` and `Ok(value)` patterns bind the exact payload type.
- `if let`, `let ... else`, refutable `for`, tuple patterns, nested patterns,
  field projection, and additional reference layers preserve exact types.
- Inferred function returns and closure captures preserve the reference.
- Generic forwarding remains `Option[&V]` for every instantiation.

#### Contextual Copy positions

- Typed bindings and assignments.
- Cast targets.
- Declared function returns.
- Known struct fields, tuple components, and array/collection elements.
- Resolved by-value function parameters and constructor components.
- Already-selected by-value method receivers, without changing dispatch.
- Resolved arithmetic, comparison, and other operator positions.
- Copy first, then ordinary widening or other legal value coercion.
- The source reference remains usable after producing an independent Copy.
- Raw pointers do not materialize.
- Non-Copy pointees fail without invoking `Clone` or another hidden operation.

#### Join behavior

- Same-type reference arms preserve the reference and union origins.
- Owned defaults anchor `??`, `unwrap_or`, and `unwrap_or_else` for Copy
  pointees.
- Borrowed defaults keep an all-reference result.
- `if`, `match`, array literals, collection literals, `??`, `unwrap_or`, and
  `unwrap_or_else` use the same rule.
- Mixed five-arm and reordered-arm cases select the same result type.
- An explicit expected type stabilizes the result.
- Removing the final owned anchor changes an inferred result to a reference.
- Owned temporaries are not implicitly borrowed to force a reference join.
- Non-Copy borrowed-success/owned-default joins fail with the D22 diagnostic.
- `?? return`, `?? break`, and `?? continue` preserve the successful payload's
  exact type because the fallback diverges.

#### Transparent origins

- `Option`, `Result`, tuples, and ephemeral structs/enums.
- `Some`/`Ok` construction and equivalent carrier construction.
- `unwrap`, `expect`, built-in `?`, user-defined `Try`, and optional chaining.
- Patterns, `match`, `if let`, `let ... else`, and refutable `for`.
- `??`, `unwrap_or`, and `unwrap_or_else`.
- Branch and multi-source origin unions.
- Non-owning combinators that forward or derive a view.
- Closure capture, compiler-generated temporaries, inlining, MIR, comptime,
  native codegen, C emission, and runtime representations.
- A contextual Copy, explicit clone, or successful remove ends the source
  origin only for the independent owned result.
- Mutation after a view's final use remains accepted as the NLL precision
  control.

#### Generic ownership contracts

- Uniform borrowed forwarding for unbounded `V`.
- Pattern bindings remain `&V` for every instantiation.
- An owned generic result requires `V: Copy`, `V: Clone` plus explicit cloning,
  or a borrowed default/result contract as specified by the ruling.

#### Diagnostics

- Mutation while a view is live names the original collection, the view
  binding, the invalidating mutation, and the later use.
- A Copy pointee offers a machine-applicable owned-type annotation only when
  its type is known and the rewrite is unambiguous.
- A non-Copy owned join explains the borrowed-success/owned-default split and
  never implies that an annotation can copy a non-Copy value.
- `.cloned()` is suggested only when the required Clone operation exists.
- A borrowed fallback is suggested only when it is lifetime-correct.
- A mixed-join diagnostic identifies the owned anchor and the relevant
  materialized reference arms.
- Carrier diagnostics identify the original storage owner rather than an
  `Option`, temporary, or eliminator.
- Clean builds emit no contextual-materialization notes.

### 2. Establish exact types before contextual adjustment

Keep expression inference, pattern projection, inferred returns, and capture
on exact types. `unwrap`, `expect`, `?`, and structural patterns must expose the
carrier's exact payload type without consulting Copy-ness.

Method lookup, overload resolution, trait selection, dynamic dispatch, and ABI
selection occur on that exact type with ordinary auto-dereferencing. Record a
contextual Copy adjustment only after a resolved context independently demands
an owned target.

Use one Sema-owned adjustment record containing at least the source expression,
exact source type, owned target type, and ordinary value coercion required after
the pointee copy. MIR and every backend consume that decision; they must not
repeat Copy-ness or demand inference.

### 3. Centralize the contextual join algorithm

Implement one Sema join resolver for every covered multi-expression form:

1. Ignore non-reaching/diverging expressions for result-type selection.
2. Preserve an exact type when all reaching expressions have that type.
3. Otherwise determine an owned candidate from an enclosing expected type or
   compatible non-reference reaching expressions, independently of arm order.
4. Materialize only compatible `&T` arms where `T: Copy` and owned `T` can
   ordinarily coerce to the candidate.
5. If no owned candidate exists, preserve compatible shared references and
   union every reaching origin.
6. Reject non-Copy ownership mismatches and attempts to borrow owned temporaries
   into a reference result.

Record the owned anchor, each materialized arm, each view-producing arm, and
the final origin union for diagnostics and MIR lowering. `??`, `unwrap_or`, and
`unwrap_or_else` use this resolver rather than private approximations.

### 4. Implement transparent-carrier origins once

Use one Sema-owned semantic origin-transfer mechanism:

- producers seed origins;
- construction records the origins of carried ephemeral values;
- projection and exact-payload elimination transfer them;
- joins union every reaching origin;
- functions and non-owning combinators propagate origins through inferred or
  declared view effects;
- contextual Copy and explicit ownership-producing operations create an
  independent result with no source-view origin.

The mechanism must cover Option, Result, tuples, ephemeral structs/enums,
patterns, control flow, optional chaining, compiler-generated temporaries,
inlining, built-in and user-defined `Try`, MIR, comptime, and both backends.
No `HashMap.get().unwrap()`-specific escape hatch is permitted. MIR consumes
Sema's resolved facts instead of creating a second origin regime.

Integrate origin invalidation with NLL so mutation is rejected only while a
possibly affected view remains live. Preserve unioned origins across branches
and accept mutation after the final use.

### 5. Converge owning-map lookup and removal across every engine

Align standard-library declarations, Sema, MIR, comptime evaluation, native
codegen, C emission, and runtime behavior:

- every owning keyed `get` returns a view into map-owned storage;
- the view's only producer origin is the receiver;
- Copy-ness never changes the producer signature or representation contract;
- `remove` transfers the payload out and removes it from map ownership;
- map destruction drops values still owned by the map exactly once;
- a removed value remains valid after map mutation/destruction;
- no semantic engine or backend synthesizes owned `Option[V]` for `get`.

A nullable-pointer representation is an implementation choice for
`Option[&V]`, not a separate source-level rule. Internal runtime ABI changes
needed to represent the uniform view must remain consistent across callers and
callees. Contextual Copy itself never changes callable ABI.

### 6. Complete general Option and Result behavior

Keep `unwrap`, `expect`, patterns, and `?` exact-payload operations. Implement
`??`, `unwrap_or`, and `unwrap_or_else` through the shared join resolver for
both Option and Result.

Implement `Option[&T].copied()` and `Option[&T].cloned()` with their exact D22
bounds and results. Their successful results are independent owned values.
Do not make these methods conditional-return operations and do not special-case
them based on a HashMap producer.

### 7. Implement the full diagnostic contract

Use the source facts recorded by contextual adjustment, join resolution, and
origin tracking to produce the diagnostics required by Sections 8.5 and 11 of
the ruling. Diagnostics must explain ownership in the user's terms, point back
through transparent carriers to the true storage owner, and offer only
applicable, lifetime-correct remedies.

Do not substitute generic type-unification failures for D22 ownership
diagnostics. Do not emit informational coercion notes on successful programs.

### 8. Retire superseded doctrine and pins

Inventory documentation, requirements, examples, tests, comments, and
migration tools for the non-conforming interpretations listed in Section 13 of
the ruling. Mark historical material conspicuously superseded or remove active
claims that conflict with D22.

Convert the former call-site-only Copy restriction fixtures into must-compile
tests for every newly authorized owned-demand position. Replace every active
claim that keyed-map `get` returns owned or conditionally-owned values.

All active doctrine must point to `docs/d22-Eric-Ruling.md`. No implementation
comment, handoff, test, or migration tool may narrow or reinterpret it.

### 9. Verify conformance in an isolated ownership/ABI batch

Run the cheapest semantic checks first, then verify every affected engine:

1. exact-type and diagnostic checks in Sema;
2. MIR validation, place/origin traces, and ownership/drop plans;
3. comptime equivalents;
4. native execution under the debug allocator;
5. C emission, compilation, and execution equivalents;
6. generic and NLL precision controls;
7. move/drop audits;
8. compiler self-check and the targeted D22 suite;
9. full build, fixpoint, audit, and test gates for the isolated batch.

Any internal lookup ABI change is part of this isolated batch. Contextual Copy
must remain an expression adjustment and must not alter dispatch or callable
ABI.

## Completion criteria

D22 is implemented only when:

- every required case in Section 14 of the ruling is active and has its stated
  verdict;
- every affected semantic engine and backend agrees on exact types, ownership,
  origins, and runtime behavior;
- map lookup never creates a second owner;
- map removal and destruction drop each owned value exactly once;
- origin tracking rejects every live-view invalidation and accepts the NLL
  controls;
- diagnostics satisfy the ruling rather than merely rejecting the program;
- all active doctrine and migration tools conform to the canonical ruling;
- the isolated build, fixpoint, audit, and test gates pass.

Passing only the current compiler tests, only one backend, or only the pleasant
Copy cases is not D22 conformance.
