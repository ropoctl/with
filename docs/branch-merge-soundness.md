# Branch-Merge Soundness: Root Cause and Fix Recommendation (#612, #579)

Report for the move-checker branch-merge soundness defect. The checker accepts a
use-after-move when one branch moves a binding and another reinitializes it (#612,
under-rejection), and rejects valid code when a diverging arm moves a binding
(#579, over-rejection). Both are the same missing primitive: a **flow-sensitive
join of move-state at control-flow merge points**.

## 1. The defect

```with
fn main(d: bool):
    var r = make()
    if d:  take(r)        // moved on this path
    else:  r = make()     // reinitialized on this path
    use2(r)               // COMPILES today — use-after-move on the d==true path
```

- Test A (`if d: take(r) else: ()`; `use2(r)`) → correctly rejects.
- Test B (above) → wrongly compiles.
- #579: a `match` arm that moves the owner and `return`s makes the *fallthrough*
  see the owner as moved (over-rejection).

`use of moved value` is the diagnostic that should fire for Test B and should NOT
fire for #579's fallthrough.

## 2. Root cause — 5 Whys

1. **Why does Test B compile?** After the `if`, Sema's state for `r` is LIVE.
2. **Why is `r` LIVE?** The `else` branch's `r = make()` set `r`'s state LIVE
   (`SemaCheck.w:8072`) and that was the last in-place write; the `then` branch's
   `take(r) → MOVED` (`:18645`) was overwritten.
3. **Why was it overwritten?** `check_if_expr` (`SemaCheck.w:7333+`) evaluates the
   branches **linearly into one shared `bind_states` vector**: it checks `then`
   (mutating `bind_states`), then checks `else` **from `then`'s residual state**,
   and only `restore_scope_states` when a branch *diverges* (`TY_NEVER`,
   `:7351`,`:7370`). It never computes the **union** of the two branch-exit states.
4. **Why no union?** `VarState` is a **binary in-place flag** (LIVE=0/MOVED=1,
   `Sema.w:52`) mutated during a single AST walk. There is no per-branch state
   vector and no join operator. Conditional moves were retrofitted with the
   `push_move_control_flow_context(0/1)` legality hack plus the divergence-restore
   patch — not a real flow-sensitive merge.
5. **Why was it built that way?** The simplest thing that handled *straight-line*
   move/use was a per-variable MOVED flag. The foundational dataflow **join at
   merge points** was never built. The binary flag is sound for straight-line code
   and for the narrow patterns the restore-patch covers, but not for the general
   branch merge.

**Root cause:** the move checker is an *in-place, single-pass, per-variable flag
mutator*, not a *flow-sensitive analysis with a lattice and a join at control-flow
merge points*. `check_match_expr` doesn't even have the partial patch `if` has — it
runs arms linearly with **no snapshot/restore at all**, so it suffers cross-arm
contamination (arm 2 inherits arm 1's moves), no divergence exclusion (#579), and
no union (#612-class), simultaneously.

## 3. Spec / requirements grounding

- §2.2 / req `2.2.1.2`: "after a move, the source binding is invalid."
- §21.1 rule 3: use-after-move is forbidden; rule 7: implicit drop is a use.
- §22: analysis is "deterministic and conservative"; "false rejection of safe code
  is compiler precision debt, not user ceremony" — so the *correct* posture is to
  reject conservatively (treat maybe-moved as moved for **use**), never to
  under-reject (accept a real use-after-move).
- req `1.1.1.14`: "Use-after-free, double-free, data races — caught at compile
  time. Always." Test B violates this **Always**.
- `mission.md`: "exactly as safe as Rust." Rust rejects Test B and accepts #579.

## 4. How the references do it

### Rust (the model) — `.reference/rust/compiler/rustc_mir_dataflow`
- **Two dual analyses** over a bitset of *move paths*: `MaybeInitializedPlaces` and
  `MaybeUninitializedPlaces` (`impls/initialized.rs`). Move = kill init / gen
  uninit; assignment = gen init / kill uninit; drop = like move
  (`drop_flag_effects.rs`).
- **Join = UNION** (`framework/lattice.rs`: `DenseBitSet::join → union`). A place is
  *maybe-init* if init on **any** predecessor; *maybe-uninit* if uninit on any.
- **Use-checking** needs the **MaybeUninitialized** half: a use requires the place
  to be *definitely initialized* = NOT maybe-uninit.
- **Drop elaboration** needs **both**: `maybe_init ∧ maybe_uninit` at a drop site →
  emit a runtime **drop flag** (`elaborate_drops.rs::drop_style`).
- **Divergence**: `MaybeReachable<T>` wrapper — `Reachable(S) ⊔ Unreachable =
  Reachable(S)`; unreachable predecessors contribute nothing.
- **Loops**: worklist fixpoint in reverse-postorder; the back-edge state is joined
  into the loop header until stable, so a value moved in the body and not reinit
  stays maybe-uninit at the header → use-after-move next iteration.

### Zig — `.reference/zig/src/Sema.zig`
- **Sidesteps it**: value semantics, no move state. Branch results merge only via
  explicit `break` operands (`zirBreak`, `Merges`); a diverging branch emits no
  `break`, so it **structurally** contributes nothing to the join. Only *types* are
  merged (`resolvePeerTypes`). Takeaway: **divergence should fall out structurally**
  (a diverged branch contributes no exit-state), not via special-casing.

### Go — `.reference/go/src/cmd/compile`
- Classic dataflow engine: liveness is **backward, join = bitwise OR (union)**,
  worklist + postorder fixpoint (`liveness/plive.go`); SCCP is a 3-level lattice
  with a `meet` at phis (`ssa/sccp.go`). Confirms the missing primitive is a
  **join at merge points with a fixpoint over loops**. (Its aside that
  move-checking wants *intersection* is wrong for **use**-checking — union is
  correct, per Rust: maybe-moved if moved on *any* path.)

### What this tells us
With already has **both halves of Rust's design, split across phases**:
- **Sema use-checking** is the *MaybeUninitialized* analysis — but its join is
  broken (linear, not union).
- **MIR drop-flag machinery** (`lower_if`/`lower_match` conditional_move_context,
  `emit_conditional_value_drop_entry`) is the *drop elaboration* — and it works.

So **With does not need a second Sema analysis or a full MIR-dataflow rewrite.** The
binary use-checking state is *sufficient* because, for **use**, maybe-moved is
treated as moved (reject). The single missing piece is a correct **join**.

## 5. Source map

- `src/Sema.w`: `VarState` LIVE/MOVED (`:52`); `bind_states`/`bind_names`
  (`:575`/`:572`); `scope_binding_index`; `save_scope_states`/`restore_scope_states`
  (`:3765`/`:3772`); `push/pop_move_control_flow_context` (`:3736`+).
- `src/SemaCheck.w`:
  - move sets MOVED: `:18645` (ident), receiver/capture consumes (`:10773`,
    `:11588`, `:15383`, `:16007`), match scrutinee.
  - reinit sets LIVE: `:8072` (assignment target).
  - use-after-move reads: `:5527` (ident) and `:8613` (field) → `use of moved value`.
  - `check_if_expr` `:7333+`: partial — divergence restore, no union, `else`
    contaminated by `then`.
  - `check_match_expr` `:9332+`: **no** snapshot/restore around arms at all.
  - **`save_scope_states` is used ONLY in `check_if_expr`** — match, if-let,
    while-let, let-else, `&&`/`||`, `?`, ternary, `for` do **no** move-state merge.

## 6. Recommendation

**Build one divergence-aware conservative-union join primitive and apply it at
every branch merge. Keep the binary use-checking state; do not rewrite to MIR
dataflow.** This achieves "exactly as safe as Rust" for use-checking with minimal
surface, and leaves the already-working MIR drop-flag elaboration untouched.

### 6.1 The join primitive

```
# pseudo-API on Sema
entry = save_scope_states()
branch_exits: Vec[Vec[i32]] = []
for each branch b:
    restore_scope_states(entry)          # every branch analyzed from the SAME entry
    btype = check(b)
    if not diverges(btype):              # TY_NEVER ⇒ contributes nothing (Zig-style)
        branch_exits.push(save_scope_states())
# join = conservative union of moves over non-diverging branches:
#   a binding is MOVED after the construct iff it is MOVED in ANY non-diverging exit;
#   LIVE iff LIVE in ALL non-diverging exits.
# (For a missing `else` / non-exhaustive fallthrough, include `entry` as a branch.)
merged = union_moved(entry, branch_exits)
restore_scope_states(merged)
```

`union_moved` over the binary lattice = "MOVED if MOVED on any branch" — i.e. the
MaybeUninitialized union, which is exactly what use-checking needs. Divergent
branches drop out (their exit is not collected), which fixes both #579 (a diverging
arm no longer leaks its move to the fallthrough) and Test B (the moving branch's
move now survives the union instead of being overwritten).

### 6.2 Apply uniformly
- `check_if_expr`: replace the linear then→else flow with: snapshot entry, check
  then from entry, check else from entry, union non-diverging exits. (Removes the
  `else`-contamination bug and adds the union.) The implicit-`else` case unions in
  the entry state.
- `check_match_expr`: snapshot entry; check **each arm from entry** (fixes cross-arm
  contamination); union non-diverging arm exits (fixes #579 + the under-rejection).
  Non-exhaustive statement-position match unions in `entry`.
- if-let / while-let / let-else / `&&` / `||` / `?` / ternary: each introduces a
  conditional path; route them through the same primitive (or a documented argument
  for why a given one cannot move an outer binding).

### 6.3 What this unblocks
- **#612** (Test B) → rejected. **#579** → accepted. Cross-arm contamination → gone.
- **#613 (loops)** becomes sound: the loop back-edge check trusts body-end state,
  which is now a correct union. (Loops still need their own back-edge join/fixpoint;
  that is #613, built on this.)

### 6.4 Risks and how to retire them
- **Latent reliance on the gap.** Tightening from under-rejection to correct
  rejection may surface real use-after-move patterns in the compiler's *own* source
  that currently compile. Each is a real bug to fix; expect a short cascade. Gate
  with the full `with build` + `:fixpoint` + fresh `:test`.
- **New over-rejections** from a too-coarse union (e.g. a binding the union marks
  MOVED that a human sees as fine). Per §22 these are acceptable *precision debt*,
  but minimize by getting divergence exclusion right (TY_NEVER) and by unioning the
  entry state for missing/non-exhaustive else/arms.
- **Performance**: `save_scope_states` copies the whole `bind_states` vector per
  branch. For deeply nested branches this is O(branches × bindings). Acceptable to
  start; if it shows up, switch to recording only the deltas (which bindings each
  branch moved) and union those.
- **Determinism**: the join must iterate bindings in index order (it does) to keep
  fixpoint/diagnostic output deterministic.

### 6.5 Verification
- New compile-error fixtures: Test B and variants (then-moves/else-reinit,
  match-arm-moves/other-arm-reinit, nested) → must report `use of moved value`.
- New behavior/compile fixtures for #579 (diverging arm moves owner; fallthrough
  uses it) → must compile.
- Keep Slice C's `behav_match_conditional_move_drop_value` + `da_*` green (the union
  must not regress the now-correct conditional-move drop-flag behavior).
- Full gates: `with build`, `:fixpoint`, `:debug-alloc-tests`,
  `rm -rf out/test-graph && with build :test` (fresh), `:test-green`.

### 6.6 Why not the full Rust rewrite
A MIR-level two-analysis dataflow with move paths is the principled maximum, but
With already has the drop-elaboration half in MIR and only needs the
MaybeUninitialized *use*-checking join, for which the binary state suffices. The
union-join primitive is the smallest change that makes the guarantee true
("exactly as safe as Rust" for use-after-move) without paying for machinery that
duplicates the working MIR drop-flag pass. If field-path granularity (partial moves
of `x.a` vs `x.b`) later needs the same flow-sensitivity, generalize `bind_states`
keys from bindings to canonical places — but that is a separate, larger step
(related to Slice E / §2.4 non-Drop-aggregate field moves), not required for #612.

## 7. Recommended sequence
1. **#612**: implement the union-join primitive; apply to `if` and `match` first
   (the two with fixtures); add Test B + #579 fixtures; run full gates; fix any
   latent use-after-move the tightening surfaces in-tree.
2. Extend the primitive to if-let/while-let/let-else/`&&`/`||`/`?`/ternary.
3. **#613 loops** (Slice D) on the sound foundation: loops `push(1)` + back-edge
   use-after-move check (reinit/move-then-break accept; `err_loop` reject).
4. Resume Slice E (non-Drop-aggregate conditional field moves) and Slice F.
