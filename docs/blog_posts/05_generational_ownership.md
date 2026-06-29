# Generational Ownership: How With Gets Rust's Safety Without Rust's Pain

*Published June 29, 2026 · Eric Hartford*

I make AI models like Dolphin and Samantha. I'm also building a systems language called With — native, no garbage collector, exactly as safe as Rust, and built to remove the suffering. This post is about the part of a systems language people argue about most: who owns memory, and who is allowed to free it.

It's also the story of how I tried to do it the Rust way, watched that approach quietly hand me a double-free, and then found a better answer hiding in a language called Vale — which I then turned inside out.

## On this page

- The trilemma everybody pretends isn't there
- With's bargain, in one line
- The bug that changed my mind
- Enter Vale: ownership you check, not prove
- The twist: Vale solves a problem With doesn't have
- So we inverted it
- How it actually works
- The part that makes it the best of both worlds
- Why it's *fun*
- The philosophy: correctness is a fact, speed is an optimization
- Where this goes

## The trilemma everybody pretends isn't there

Pick a systems language and you've picked a way to lose.

**C** lets you do anything, including free the same pointer twice on a Tuesday and corrupt a heap you won't notice until Friday. Fast. Dangerous. Yours.

**Go** and friends bolt on a garbage collector. Safe, pleasant, and then the GC walks in during your 99th-percentile frame and everybody notices.

**Rust** is the one that actually solved memory safety without a GC — and I have enormous respect for it. But the price is the borrow checker, and you pay it on *every program*, forever. Lifetime parameters threading through your APIs. `PhantomData<&'a T>`. `where T: 'a` bounds metastasizing across generics. `Rc<RefCell<T>>` when you just wanted two things to point at a third. `Pin<Box<dyn Future>>` because the async model leaked into your types. The safety is real. So is the tax.

With's entire thesis is that this is a false choice. You can have Rust-level safety, no GC, *and* a language that feels like it's on your side. The ownership model is where that thesis lives or dies.

## With's bargain, in one line

Every systems language makes one decision about ownership. Here's With's:

> **Ownership is persistent. Borrowing is ephemeral. Relationships are handles.**

Values have exactly one owner. References exist only in local scope — you cannot store a `&T` in a struct, return a borrow that outlives its source, or build a graph out of pointers. If something needs to live a long time, you *own* it or you hold a *handle* (a typed index with a generation, like `Handle[Texture]`).

```with
// Not this — a stored reference drags lifetimes through your whole type system
type Lexer { source: &str }        // not allowed in safe With

// This — own the data, or hold a handle into a table
type Lexer { source: str }         // owned
type Lexer { source: SourceId }    // handle
```

That one rule deletes ninety percent of Rust's cognitive load. No `'a`. No lifetime bounds. None. The compiler still guarantees no use-after-free, no double-free, no data races — it just doesn't make your function signatures carry the proof.

This sounds like the whole story. It isn't. There's a crack, and I fell straight into it.

## The bug that changed my mind

Here is the most innocent code in the world:

```with
var r = make_resource()
take(r)              // consumes r — take owns it now, and drops it
r = make_resource()  // reassign r to a fresh resource
use(r)
// end of scope: r is dropped
```

You moved `r` into `take`, which consumed and freed it. Then you reassigned `r` to a new value. This is the fold loop. This is `acc = combine(acc, next())`. This is `p = realloc(p, n)`. It is *everywhere*, especially in code you migrate from C.

And it double-freed.

When you reassign a variable that owns a `Drop` type, the compiler emits a "drop the old value before overwriting it" step. But the old value was already moved out and freed by `take`. So the reassignment dutifully freed it again. Print the drop count: you get 3 where the answer is 2.

The fix everybody reaches for — the fix *Rust* reaches for — is a static dataflow pass. Track, at compile time, which variables are "definitely moved" at each program point. If the old value is provably moved, *delete* the drop-before-overwrite. Rust calls this `elaborate_drops`, and its `DropStyle` enum is genuinely elegant: a drop is `Dead` (provably moved — delete it), `Static` (provably live — emit it), or `Conditional` (maybe-moved — guard it with a runtime drop flag).

So I built that. And then I watched it hand me a *leak* on a slightly different shape — because the analysis that's supposed to delete the dead drop also, in one case, deleted a live one.

That's the moment the lesson landed:

> If your static analysis *is* your safety, then a bug in your static analysis *is* a memory-safety hole.

`elaborate_drops` is beautiful when it's correct. When it's subtly wrong — and analyses over real control flow are subtly wrong all the time — it doesn't give you a compile error. It gives you undefined behavior, shipped. I had spent days making a clever pass that was load-bearing for safety, which is exactly the kind of thing a clever pass should never be.

I needed correctness to come from somewhere a bug couldn't reach.

## Enter Vale: ownership you check, not prove

[Vale](https://vale.dev) is a systems language with one gorgeous idea: **generational references.**

Every heap object carries a small integer — a *generation* — in its header. A reference carries a snapshot of the generation it saw when it was created. To use the reference, you compare: does the object's current generation still match my snapshot? If yes, the object is the one I think it is. If no, it was freed (and the generation got bumped), so the reference is stale and the access is caught.

No borrow checker. No lifetimes. No proving anything to a compiler. You just *ask the object at runtime whether it's still alive.* Use-after-free becomes a checked, recoverable fact instead of a static obligation. It's the cleverness of a GC's safety with none of a GC's tracing.

This was the shape I wanted. Correctness from a runtime truth — a generation counter — that no compiler-pass bug can corrupt. So I read Vale's implementation cover to cover. And that's where it got interesting, because **Vale doesn't do what I assumed it did.**

## The twist: Vale solves a problem With doesn't have

Here's what I found in Vale's source, and it reframed everything.

Vale's generations protect **non-owning references** — borrows and weak pointers that get *stored* and *outlive* the thing they point at. That's the use-after-free problem, and it's the hard one, because a stored borrow can dangle in a thousand ways.

But Vale's **owning** reference is *not* generation-checked. An owner can't even be discarded implicitly — it must be moved or destructured — and when it drops, it just unconditionally frees and bumps the generation. **Vale's owner-drop safety comes from its static move checker**, not from a runtime check. Vale never had my double-free problem because its move checker structurally forbids the shape — single ownership, linear, no second owner to free.

And to make all those *borrow* checks cheap, Vale built an extraordinary amount of machinery: "Hybrid Generational Memory" with scope-tethering, and then **regions** — where immutability becomes a generic type parameter on every struct and function so the compiler can prove a borrow is live and skip the check. Their own design docs are candid: it causes a `2^R` monomorphization blow-up, required rewriting the instantiator, is "genuinely complex," and *still* isn't fully zero-cost.

Then I looked back at With's one-line bargain and laughed, because **borrowing is ephemeral.** With borrows can't be stored, can't escape, can't outlive their source — the language forbids it structurally. The entire problem Vale's generations exist to solve, and the entire regions apparatus built to make them fast, **does not apply to us.** We deleted it in the spec on page one.

So Vale spends its generations on the one problem we don't have. Which left a delicious question: *what should we spend ours on?*

## So we inverted it

Vale: **check the borrows, trust the static checker for the owner.**

With: **the borrows are structurally safe, so spend the generation on the owner's drop.**

That single inversion is the whole design. We take Vale's runtime-truth idea — a generation in the allocation header, bumped on free — and point it precisely at the thing that bit me: the owner's drop.

- A drop asks the allocator: *is this still the allocation I owned, with my generation?* Match → run the destructor, free, bump. Stale → a prior owner already freed it → **no-op.**
- Double-free becomes impossible *by construction*: only the holder of the matching generation ever frees, and the bump invalidates every stale copy. Reassign-after-move is correct because the moved-out `r` finds its generation stale and quietly does nothing.

And here's the move that pays off the lesson from the bug. The static move analysis — the very pass that betrayed me — **doesn't go away. It gets demoted.** It is no longer the safety mechanism. It is now two things, neither load-bearing:

1. A **diagnostic**: using a moved-from variable is almost always a mistake, so we still flag it as a compile error — as a courtesy, not a guarantee.
2. A **zero-cost optimizer**: where it *proves* a value has a single owner that's never moved (the overwhelming common case), the generation check is provably redundant and we **elide it entirely** — the drop compiles to an unconditional free, byte-for-byte what a static-only model would emit.

The consequence is the thing I was chasing:

> A bug in the move analysis can now only cost a redundant compare — a wasted CPU cycle. It can never be a double-free or a leak, because correctness lives in the runtime generation, not in the proof.

That is the exact inverse of `elaborate_drops`, where the analysis *is* the safety and a bug is UB. We kept the smart pass for its speed and its nice error messages, and we took away its ability to hurt you.

## How it actually works

The mechanism, in full:

**The generation lives in the allocation header.** The allocator stamps a generation on every allocation and bumps it on free — and on reuse it writes a *random* generation, not just `+1`, so a recycled slot can't accidentally match a stale snapshot. This is the same counter the language already exposes in `Handle` and `SlotMap` (§6): one concept, used everywhere.

**An owned value carries the generation it acquired.** A move is a plain `memcpy` that copies that snapshot to the new binding. The source keeps its now-stale snapshot. No source-zeroing, no bookkeeping, no "is this moved?" proof required for safety.

**Drop is generation-checked:**

```
if value.gen == header(value.ptr).gen:   // still the live owner?
    <run the destructor body>
    free(value.ptr)                       // freeing bumps the header generation
// else: stale — a prior owner already freed it → no-op
```

**Reassign-after-move, traced:**

```with
var r = make()    // r owns allocation A, generation g
take(r)           // take owns r, drops it → frees A, bumps A to g+1
r = make()        // drop-before-overwrite: r's snapshot g ≠ A's g+1 → no-op
                  // r now owns a fresh allocation B, generation h
use(r)
// scope end: r's snapshot h == B's h → destructor + free. Exactly one free. No leak.
```

No drop flags. No conditional-drop elaboration. No per-path bookkeeping. The generation settles it.

And one quiet advantage over Vale falls out of an existing piece of our runtime. Vale can never return freed memory to the OS, because it needs the generation field to stay readable forever. With already has a slab-range oracle (`rt_payload_start_is_owned`) that knows whether an address is inside a live allocation region. So our check is two cheap levels: *is this address in a live region?* (handles memory returned to the OS — stale → no-op) and *does the generation match?* (handles in-region reuse). **We get to free memory back to the OS. Vale doesn't.**

The cost, honestly stated:

| Situation | Cost |
|---|---|
| A single, never-moved owner (the common case) | **Zero** — check and bump elided; identical codegen to a static model |
| Genuinely dynamic ownership (conditional moves, reassignment of a maybe-moved binding, ownership moved through a data structure) | One generation compare + one bump — a single, well-predicted branch |

We pay a branch exactly where ownership is actually dynamic, and nowhere else. And we explicitly **do not** build Vale's regions or HGM — ephemeral borrows make the thing that drove Vale's complexity unnecessary. Our entire "optimizer" is the move analysis deciding whether one drop needs one check. That's it.

## The part that makes it the best of both worlds

**Versus Rust.** Same safety guarantees — no use-after-free, no double-free, no data races — with *none* of the lifetime ceremony, and a robustness Rust's drop elaboration doesn't have: in Rust a bug in `elaborate_drops` is undefined behavior; in With a bug in the equivalent pass is a wasted cycle. We're not just as safe as Rust. On the drop path, we're harder to *break*.

**Versus Vale.** Same beautiful runtime-truth idea — a generation that catches what static proofs miss — but we spend it where it actually earns its keep for us (the owner's drop), and we skip the entire regions/HGM apparatus that Vale needed to make borrow-checking fast, because ephemeral borrows already made borrows free. We even get to release memory to the OS, which Vale's design can't.

**Versus C.** Safe. **Versus GC.** No pauses, no runtime, no tracing.

We took Vale's correctness-from-runtime and Rust's zero-cost-where-provable and let each cover the other's weakness: the generation makes the optimizer non-load-bearing, and the optimizer makes the generation free on the hot path. That's not a compromise between the two. It's both, at once.

## Why it's *fun*

All of that is the engineering. Here's what it feels like, which is the part I actually care about.

You write the obvious thing, and it compiles.

```with
// A fold. This is the loop that double-freed me for a week. It just works now.
var acc = Summary.empty()
for line in lines:
    acc = acc.merge(parse(line))   // moves acc in, gets a new acc back
return acc

// Reassign a file handle in a loop. No drop flag, no ceremony, no leak.
var current = open(paths[0])
for p in paths[1..]:
    current = open(p)              // old handle's drop is a no-op; new one is live
```

No `'a`. No `where T: 'a`. No `PhantomData`. No `Rc<RefCell<T>>` because two things needed to see a third — you hand out a `Handle` and move on. No `Pin<Box<dyn Future>>` leaking the async machine into your types. No moment where you wanted to express something true and obvious and the compiler made you prove it in a language of apostrophes first.

The borrow checker, when you do hit it, is checking *aliasing* — "don't mutate this while something else is reading it" — which is a real bug and a fair fight. It is not checking whether you've satisfied a lifetime calculus, because there isn't one.

That's the difference I want people to feel. In Rust, the compiler is a brilliant adversary you learn to negotiate with. In With, the compiler did the hard part — put a generation in a header — so that you get to just write the program. Safety stops being a thing you argue about and becomes a thing that's already true.

## The philosophy: correctness is a fact, speed is an optimization

If there's one idea I'd carve over the door, it's this.

Most safe languages couple correctness to a clever analysis: the analysis succeeds, therefore the program is safe. When the analysis is wrong — and analyses over real control flow are wrong in the corners — your safety is wrong too, silently.

With decouples them. **Correctness is a runtime fact** — a generation either matches or it doesn't, and no compiler bug can make a stale generation match a live one. **Speed is an optional optimization** — a static pass that removes checks it can prove redundant. If the optimizer is perfect, you pay nothing. If the optimizer has a bug, you pay a cycle. Either way, your memory is safe.

That's the bargain that lets With be opinionated *and* trustworthy at the same time: we can be aggressive about ergonomics, aggressive about eliminating ceremony, aggressive about "the compiler should just figure it out" — because the floor underneath all of it is a runtime invariant that doesn't depend on us being clever, only on us being correct *once*, in one counter, in one allocator.

Rust taught the world that you don't need a GC to be safe. Vale taught me that you don't need a borrow checker to be safe. With's job is to take both lessons and hand you a language where safety is the default, zero-cost is the common case, and writing the obvious code is — finally — fun.

## Where this goes

The model is in the spec now (§2.5, Generational Ownership) and the implementation notes (§2.6). The runtime substrate is already partly there — the allocator that knows what it owns. The work ahead is the generation field, the bump on free, the generation-checked drop, and re-pointing the old move analysis from "safety" to "optimizer." The two failed half-measures — runtime drop flags and static dead-drop elaboration — are retired, on purpose, in writing, so no future version of me rebuilds the trap.

If you've ever loved what Rust protects you from but resented how much it makes you say to get there — this is the language I'm building for you.
