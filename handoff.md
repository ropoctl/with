# Handoff — #691 "the wide flip" + build-perf + doctrine (2026-07-22)

> **CURRENT OVERRIDE — D22 (2026-07-23): A new decision has been made, but
> implementation is still in progress.** Specification v7.2 and
> `docs/decisions.md` D22 now lead: owning keyed-map `get` uniformly returns
> `Option[&V]`, `remove` returns `Option[V]`, `&Copy` materializes only under
> established owned-value demand, patterns preserve exact projected types, and
> view origins survive transparent carriers and eliminators. This doctrine pass
> deliberately does **not** implement those rules. Treat contradictory behavior
> in the current compiler as NON-COMPLIANT, not as precedent. The historical
> immediate-next-action below remains useful provenance for the interrupted
> ownership investigation, but it is not authorization to bypass D22 or to
> implement D22 before its implementation design is approved.

Audience: the next model/agent resuming this work. Eric Hartford is the sole
author of With (a self-hosting systems language, ~3 months old, solo). Read
`docs/mission.md`, `CLAUDE.md`/`AGENTS.md` (identical), and `docs/decisions.md`
first — they are the bible. This file assumes you have.

Scratchpad root (session-specific, referenced below as `$SP`):
`/private/tmp/claude-501/-Users-eric-with/720b15d2-b693-4f4d-a7e0-b1848181898f/scratchpad`

---

## 0. TL;DR — where we are RIGHT NOW

- **HEAD = `323df635`.** On top of it there is a **large uncommitted working
  tree** (the flip + spec + doctrine). `git status` = 21 modified files +
  `handoff.md`. NOTHING of the flip is committed.
- **The flip is source-complete and checker-clean under seed semantics**
  (`with check src/main.w` = ok), but the **flip-carrying stage1 SEGFAULTS**
  when it checks `src/main.w`. This is the one and only blocker. It is
  **fully root-caused** (see §3) down to the exact faulting instruction and the
  exact producer function. The fix is designed and hand-traced but NOT yet
  applied — Eric asked me to hand-trace to *guarantee* correctness before
  coding, which disproved my first hypothesis and produced the real one.
- Two runtime bugs were found this session. **One is already fixed**
  (nested-Vec member-drop glue, `CodegenDispatch.w`). The **other is the
  blocker** (moved-field snapshot/restore pairing → OOB vec read).
- **The §2.5.1 spec ruling is landed and Eric-blessed** (spec line 599). Per
  D20, the implementation is now formally NON-COMPLIANT until the flip ships.
- Build-perf quick wins are committed (`323df635` etc.) and MEASURED. Reseed of
  the compiler was deliberately deferred to the flip's battery (§7).

**Immediate next action:** apply the `restore_moved_field_lengths` pairing fix
(§3.4), harden `with_vec_get_ptr` to trap on OOB (§3.5), rebuild `:dev`,
re-run the flip self-check, then run the full flip validation (§6).

---

## 1. The mission frame (why this matters)

`docs/mission.md` was amended (Eric-blessed) with the leak-freedom invariant:
memory is the first resource; every allocation is owned from birth and released
by its owner's scope; **stricter than Rust — Rust calls leaking safe, With
calls it a defect**; leaking must take deliberate, visible effort. The language
is named for the `with` scope. If the *creators* can leak by accident, the
design is wrong, not the programmer.

This is `docs/decisions.md` **D18** — the five-layer conceptual root cause of
the leak pattern (read it in full; it is the intellectual spine of the whole
campaign). The flip (#691) is D18's **first installment**, not the whole cure;
extern ownership contracts and Vale-style linear-consumption enforcement come
later.

---

## 2. The flip (#691) — what it is and what was migrated

### 2.1 The one-line semantic change
`src/Sema.w:4772`, inside `type_needs_drop` (fn starts `src/Sema.w:4758`):

```
// BEFORE (A5/#606 — POD-element Vecs leak by design, #608):
if base_sym == self.syms.vec:
    return self.type_needs_drop(self.get_generic_inst_arg(resolved as i32, 0))
// AFTER (#691/D18):
if base_sym == self.syms.vec:
    return 1
```

Now **every `Vec[T]` needs drop** (owns + frees its heap buffer at scope exit),
regardless of element POD-ness. Element destructors still run only when the
element type needs them.

### 2.2 Codegen glue (FIXED this session)
`src/CodegenDispatch.w`, `mir_emit_drop_vec_ptr` (~line 4274). Previously
returned `false` (no-op) for POD-element Vecs. Now: always frees the buffer;
runs element drops only when `type_needs_drop_frozen(elem) != 0`. The null
guard inside `mir_emit_vec_free_ptr` makes a blanked (moved-from) header a
no-op. **Verified:** `$SP/roundtrip.w` (nested struct holding `Vec[i32]`) went
from `leak count=1` → `leak count=0`, value output correct (8).

### 2.3 The 78 transfer-site migration (DONE, checker-clean)
The flip makes non-Copy `Vec` params that are consumed/escape require an
explicit `move`. 78 sites surfaced. Partitioned by the `move-sites` analysis
into **50 last-use** (mechanically safe for `move`) + **28 design**
(live-after / in-loop — hand-decided).

- **50 last-use sites**: applied mechanically via `$SP/apply_moves.w` (a pure
  byte-splicer — no compiler imports, so the seed runs it while the tree is
  mid-flip) driven by the move-sites TSV. See §5 for why the "proper" tool
  (`tools/migrate_method_arg_moves.w`) could not run (issue #705).
- **28 design sites**: hand-migrated. The important pattern was the
  **take-and-return diagnostics/pool flow** through `sync_from_sema`. Files
  touched: `src/Resolve.w`, `src/ComptimeTransform.w`, `src/compiler/Frontend.w`
  (9 constructor sites), `src/compiler/Compilation.w`, `src/main.w`,
  `src/Parser.w`, `src/BuildGraphMaterialize.w`, `src/CImport.w`,
  `src/compiler/Link.w`, `lib/std/cfg/stackify.w`.

Key hand-migration subtleties (all in the working tree already):
- `InternPool` is `Copy` (`src/InternPool.w:85 impl Copy for InternPool`), so
  pool args must NOT be `move`d — only `DiagnosticList` (non-Copy) needs it.
  Several first-pass `move self.pool` edits were reverted for this reason.
- `sync_from_sema` (`src/compiler/Zcu.w:398`) consumes `sema` by value and reads
  `sema.diags`; every call site now does `self.zcu.diagnostics = move sema.diags`
  BEFORE `sync_from_sema(move sema)`. In `run_mir_lower` the `lower_async_module`
  path needed a local `var _async_diags = sema.diags; ...(move _async_diags)`
  then `sema.diags = async_artifacts.diags` so the later sync still has a live
  `sema.diags`.
- **Dead fields removed**: `Zcu.typed_expr_types/typed_binding_types/
  typed_binding_names/typed_binding_muts` were written by `sync_from_sema` and
  never read → deleted from `src/compiler/Zcu.w`. `src/Lsp.w:492` was the only
  reader-ish site; repointed to `sema.typed_expr_types`.
- `src/CodegenTraits.w` `generate_default_trait_method_for_impl_ext`: the
  save/restore of `type_binding_syms/types` used a **move-out/move-back** of the
  vec headers (`let saved = self.x; ...; self.x = saved`), which the flip's
  checker correctly rejected (can't push to a moved-out field; pre-flip it
  aliased a live buffer across realloc). Replaced with **length-remember +
  pop-back** scoping. This was the FIRST bug the flip caught — a real aliasing
  latent bug, exactly the class the campaign exists to kill.

### 2.4 Test/audit expectations flipped (DONE)
`tools/drop_audit.w`: the POD `pod_cell` pins changed from `expect_clean:
false` (EXPECT-LEAK) to `expect_clean: true` (EXPECT-CLEAN); cell names
`pod_vec_scope_exit/EXPECT-LEAK` → `.../EXPECT-CLEAN` (same for reassign);
header comments updated to #691/D18. This auditor must go GREEN post-flip (POD
Vec cells now demanded clean).

---

## 3. THE BLOCKER — moved-field snapshot/restore OOB (FULLY ROOT-CAUSED)

Filed as **issue #706**. This is the only thing between the working tree and a
shippable flip.

### 3.1 Symptom
Flip-carrying `./out/bootstrap/bin/with-stage1 check src/main.w` exits **139
(SEGV)**, EXC_BAD_ACCESS at address **0x0**. Seed `with check src/main.w` = ok
(seed doesn't have the flip). Small inputs check fine; only compiler-scale
`src/main.w` trips it. `lib/std/vec.w` also trips it (rc=1).

### 3.2 Crash site + caller chain (recovered via breakpoint-at-fault-addr)
```
frame#0 MirBuilder.moved_field_path_matches   (src/MirLower.w:409)
frame#1 MirBuilder.mark_place_field_moved     (src/MirLower.w:473)
frame#2 MirBuilder.consume_moved_operand      (src/MirLower.w:~827)
frame#3 MirBuilder.assign_operand_to_place    (src/MirLower.w:~3724)
frame#4 MirBuilder.lower_block_mode
frame#5 lower_fn_with_sig → lower_fn → lower_module
frame#8 Compilation.run_mir_lower
```
(A "line 562/main.w" attribution in the raw bt is bogus debug-info; trust the
symbol names. To recover bt at all, set the breakpoint AT the fault address
`0x100622308` then `run` — a plain crash bt shows only frame#0.)

### 3.3 Instruction-level root cause (disassembly + register dump — PROVEN)
The faulting instruction is `ldr w26, [x0]` where `x0 = 0` returned by
`with_vec_get_ptr`. At crash, `self` = x21. Dumping the five record-family vec
headers at `self+0x738` showed **all healthy**: `moved_field_path_kinds` =
`{ptr=0x36fefdc10, len=1, cap=8, elem=4}`.

The faulting call was `with_vec_get_ptr(moved_field_path_kinds, idx=1)` —
**index 1 into a length-1 vector**. `with_vec_get_ptr` (`rt/rt_core.w:2352`)
returns `0` (null) on out-of-bounds instead of trapping; the caller
(`moved_field_path_matches`, `src/MirLower.w:418`) dereferences it unchecked.

Why idx=1: in `moved_field_path_matches`, `stored_start =
moved_field_path_starts.get(idx)` = **1**, and `path_count` ≥ 1, so it reads
`kinds.get(stored_start + 0) = kinds.get(1)`. But `kinds.len == 1`. So the
ENTRY (`starts[idx]=1, counts[idx]≥1`) points PAST the end of the path arrays.
The entry array and the path arrays are **out of sync**.

### 3.4 The producer (hand-traced — THIS is the fix target)
Only one code path can desync the two families: `restore_moved_field_lengths`
(`src/MirLower.w:366`):
```
fn restore_moved_field_lengths(entry_len: i32, path_len: i32):
    while self.moved_field_base_locals.len() as i32 > entry_len:
        self.moved_field_base_locals.pop(); self.moved_field_path_starts.pop(); self.moved_field_path_counts.pop()
    while self.moved_field_path_kinds.len() as i32 > path_len:
        self.moved_field_path_kinds.pop(); self.moved_field_path_syms.pop()
```
The recorder `mark_place_field_moved` (`src/MirLower.w:473`, push block
484–490) pushes kinds/syms FIRST, then the entry triple — so in isolation they
are always consistent. The desync comes from a **mismatched snapshot pair**
passed to restore: an entry survives (entry_len kept it) while its path data
was popped (path_len cut below its `stored_start`). This is the **#696 /
move-checker-drift class** (see memory `move-checker-drift-class`): per-edge
save/restore transfer functions drifting.

Snapshot/restore call sites to audit (grep `restore_moved_field_lengths` and
`branch_moved_field_len`/`branch_moved_field_path_len`):
- if-expr: capture `src/MirLower.w:5461-5462`, restore `5507` and `5522`.
- match: capture `src/MirLower.w:7883-7884`, restore `7947`.
- (grep for any others — those two are the confirmed capture/restore pairs.)

The flip DETONATED this latent bug: pre-flip, POD `Vec` fields never produced
field-move records, so the path arrays were usually empty and the desync never
had data to point past. Post-flip, every `Vec` field can be moved → records
exist → the stale snapshot pair now indexes real out-of-bounds memory.

**The designed fix (hand-trace it to a contradiction before coding — Eric's
standing demand):** snapshot and restore the two families as ONE atomic unit so
an entry can never outlive its path data. Two options:
- (a) PREFERRED — after restoring, also drop any entry whose
  `stored_start + count > kinds.len` (robust to a wrong snapshot pair rather
  than assuming pairs are always correct), OR key entries to a `path_epoch`.
- (b) make capture/restore a single `{entry_len, path_len}` value produced and
  consumed in lockstep, plus an audit-build invariant check that after every
  restore, for all i: `starts[i] + counts[i] <= kinds.len`.
The hand-trace requirement: prove `starts[idx] + count > kinds.len` becomes
unconstructible after the fix.

### 3.5 Runtime hardening (do alongside — "No Silent Fallbacks")
`with_vec_get_ptr` returning null on OOB is a silent fallback that turned a
one-line diagnostic into an all-day segfault hunt. Per CLAUDE.md "No Silent
Fallbacks", make OOB `with_vec_get_ptr` (and siblings) **trap loudly** with a
diagnostic (`with_panic_core`) instead of returning 0. `rt/rt_core.w:2352`.
Its own small commit; would have caught this bug instantly.

### 3.6 How to reproduce / drive the fix
```
with build :dev                                   # builds flip stage1
./out/bootstrap/bin/with-stage1 check src/main.w  # expect 139 until fixed
# instruction-level (all confirmed working this session):
lldb --batch -o 'run check src/main.w' -k 'register read x21' \
  -k 'memory read -f x -s 8 -c 20 `$x21 + 0x738`' -k 'quit' -- ./out/bootstrap/bin/with-stage1
```
There is NO minimal repro yet — `$SP/roundtrip.w` does NOT reproduce it (it
exercised the drop-glue bug, now fixed). Toward a minimal repro: dump
`builder.body.fn_sym` at crash to identify WHICH lowered fn hits the stale
snapshot, then reduce that fn. Or just fix the pairing (the trace already
proves the mechanism; a repro is confirmation, not discovery).

---

## 4. Spec change (LANDED, Eric-blessed) — D20 context

`docs/with-specification.md:599`, in §2.5.1 (Reset-on-move and the null drop).
This went through the full "do the thing" procedure (§8) and Eric blessed the
exact wording (sentence 2 cut as redundant with §2.2 drop-on-reassignment at
spec line ~471; sentence 3's `forget` construct-promise stripped):

> **Ownership is a property of the handle, not of its contents.** Every value
> that owns heap — a container, a box, an owned buffer — releases it when its
> owner's scope ends, regardless of whether its *elements* need destruction:
> `Vec[i32]` frees its buffer exactly as `Vec[File]` does; trivially-copyable
> elements merely skip the per-element destructor loop. (Replacement is already
> covered by §2.2's drop-on-reassignment.) Leaking memory therefore requires a
> deliberate, visible act — owning the memory from a named scope — never
> inaction: a program that does nothing special does not leak.

Note §2.5.4 (spec ~line 672) ALREADY said With-owned values are "those that
carry a Drop (an allocation buffer, ...)". The A5/#608 POD carve-out was NEVER
in the spec — the implementation was silently non-compliant. The flip is
compliance work.

**CRITICAL PROCESS RULE (D20, and CLAUDE.md "The Specification Leads"):** the
spec LEADS. A spec change makes the product non-compliant until code conforms;
you NEVER hold spec text back or revert it to match code. AND only Eric authors
or blesses the exact normative words — a directive/mission/agreed direction is
NOT approval of wording. I violated this earlier by authoring the paragraph on
the strength of the D18 directive; Eric corrected it; it is now enshrined. Do
not repeat it.

---

## 5. Doctrine changes (LANDED this session)

All in `CLAUDE.md` + `AGENTS.md` (kept byte-identical — `cp CLAUDE.md AGENTS.md`;
they had silently drifted since Jul 18, itself a defect) and
`docs/decisions.md`:

- **D18** — leak-freedom is a language invariant (the five-layer root cause).
- **D19** — verification cost scales with blast radius; batteries bless
  BATCHES not each commit; only ownership/drop/codegen-determinism/ABI changes
  sit alone; build-system requests must cost what they name.
- **D20** — the spec leads; spec changes are solemn (Eric blesses exact words).
- **"Do the thing" procedure** — new CLAUDE.md section under "The Specification
  Leads". Every spec change + most decisions surfaced to Eric go through: (1)
  what the reference projects do (VERIFIED in `.reference/`), (2) what the spec
  currently says (quote it; check for duplication/existing rule), (3) mission
  fit + most-with-y, (4) a committed BDFL prediction with confidence. Then Eric
  rules.

Memory files written (`~/.claude/projects/-Users-eric-with/memory/`):
`spec-is-the-bible`, `edit-indentation-dislodge`, `bisection-verdict-hygiene`
(all indexed in MEMORY.md).

---

## 6. Verification battery — how to run it, current status

Per D19, the flip is an **isolated batch** (ownership/drop change) — it gets the
FULL battery including `:move-audit` and `:drop-audit`, and sits alone.

```
with build                     # full stage chain, ~9min
with build :fixpoint           # stage2==stage3, ~5min. NEW: also produces
                               #   out/.build-state/fixpoint-evidence.json (§7)
./out/stage/bin/with-stage2 analyze src/main.w audit:all   # 2.2M facts, expect 0 violations
with build :move-audit         # move-checker matrix, must be green
with build :drop-audit         # DROP MATRIX — POD cells now EXPECT-CLEAN (§2.4)
with build :test               # umbrella (default ceiling is 64GiB now, §7)
with build :test-green
with build :last-green
# reseed only after all green, on the COMMITTED tree:
with build :update-seed        # now ~1s fast-path (§7)
with build :install-user
```

**Post-flip specific checks (the payoff):**
- `./out/bootstrap/bin/with-stage1 run --debug-alloc $SP/readleak.w` → expect
  `leak count=0` (was 252 pre-flip).
- `with build :drop-audit` POD cells green.
- Re-measure battery runner peak RSS (should fall dramatically — see #702).

The battery has NOT been run on the flip tree (blocked by §3). Everything below
§3's line was validated only via `with check` (seed) + flip `:dev` static check.

---

## 7. Build-perf work (COMMITTED, measured) — context for the 40-min pain

Eric nearly abandoned the project over build times. These landed and are
measured (all `#702`/D19):

| commit | what | measured |
|---|---|---|
| `bd027455` | streaming cache-fingerprint hash (no `++` payload copies); serial actions spawn workers again (partial revert of #683) | killed ~5 leaked full-file copies/hash; actions' interpreter state dies with worker |
| `49629f50` | `WITH_ALLOC_SYSTEM=1` routes heap through libSystem malloc → `leaks`/`heap`/Instruments SEE the With heap | the diagnostic that found everything after |
| `d6cd3c13` | ComptimeEval `Vec.push` O(n²)→O(1) tail-append, copy-free `pop` | fixed 6/12GiB single-request killer |
| `8b0a144d` | default build memory ceiling 32→64 GiB | interim; 8GB is the real bar (#702), restored as flip acceptance test |
| `9d260b6b` | `:update-seed`/`:install-user` FAST PATH — verify manifest sha + copy, no graph eval | reseed 10s/5min → **~1s** |
| `323df635` | serialized evaluated-graph cache; cacheable selfcheck (kind-19); fixpoint evidence written-once-read-thereafter | warm `with build :<lane>` **92.8s→5.5s**; `:test` transition 1030s→567s; `:last-green` 360s→63s |

Residual: ~4s/invocation is the runner self-hashing its own 105MB binary for
the graph-cache key → **#704** (embed self-sha at link time → ~1.5s).

**Deferred:** the compiler was NOT reseeded after these. The flip's battery will
reseed once, on the committed flip tree. Until then, use `out/release/bin/with`
directly for the new speeds; the installed seed (`~/.local/bin/with`,
`src/main`) is `8b0a144d`-era.

**Open follow-ups filed:** #701 (battery ceiling death — mitigated), #702 (8GB
budget = flip acceptance test; live-heap attribution posted showing residual is
#608 growth ladders), #703 (debug-alloc ledger scale + site attribution), #704
(link-time self-sha), #705 (tool-mode compiler-library tools fail codegen — §5),
#706 (THE BLOCKER).

---

## 8. Tools built / how the migration was driven

- **`analyze <entry> move-sites`** (`src/Analysis.w` + `src/compiler/
  Compilation.w` routing + CLAUDE.md docs): classifies every plain-arg→owned-
  param transfer site with a liveness verdict — `last-use` (safe for mechanical
  `move`), `live-after`/`in-loop` (design decision). Committed in `93aecbe1`.
  Emits TSV: `file:line:col \t root \t shape \t spellable \t verdict \t loop \t
  callee \t param`. Runs UNDER check errors (semantic-snapshot path).
- **`analyze <entry> 'explain:effect:<fn>[:<param>]'`**: first-setter provenance
  chain for each ownership-forcing effect bit. Committed `93aecbe1`. Diagnosed
  the 626-escalation regression earlier this session.
- **`$SP/apply_moves.w`**: pure byte-splicer (no compiler imports → seed runs it
  mid-flip). Reads a move-sites TSV, filters to `last-use`, verifies the token
  at each site matches the TSV's recorded root ident, splices `move ` back-to-
  front per file. Handles `<embedded-std>/`→`lib/` path mapping. `--apply` to
  write. Applied the 50 mechanical sites. (Promote to `tools/` once #705 is
  fixed or as-is.)
- **`tools/migrate_method_arg_moves.w`**: the integrated tool (extended this
  session with `--liveness <tsv>` + `--from-tsv`). BLOCKED by **#705**: any tool
  pulling `compiler.Compilation` as a library currently fails at codegen
  (`unresolved type for field ... MirBuilder.cur_bb`, CiMigrate structs) — even
  pristine HEAD copies. `apply_moves.w` is the workaround.

Regenerate the partition after any change:
```
./out/bootstrap/bin/with-stage1 analyze src/main.w move-sites 2>/dev/null \
  | grep -v "^error\|^ \|^-" > $SP/flip-live.tsv
```

---

## 9. Key file/line reference index

Source (working-tree, uncommitted unless noted):
- `src/Sema.w:4758` `type_needs_drop`; `:4772` the flip arm.
- `src/CodegenDispatch.w` `mir_emit_drop_vec_ptr` (~4274, FIXED); element-drop
  loop `mir_emit_vec_element_drops_ptr` (~4196); free `mir_emit_vec_free_ptr`
  (~4249); dispatch `mir_emit_drop_ptr_for_sema_type` (~4284).
- `src/MirLower.w`: `restore_moved_field_lengths:366`; `moved_field_path_matches
  :409`; `mark_place_field_moved:473` (push block 484–490);
  `remove_moved_field_entry:492`; if-snapshot `5461`, restore `5507`/`5522`;
  match-snapshot `7883`, restore `7947`. (§3 is entirely here.)
- `rt/rt_core.w:2352` `with_vec_get_ptr` (silent-null-on-OOB — §3.5); `vec_grow`
  ~2328 (frees old buffer correctly — proves discipline is achievable).
- `src/compiler/Zcu.w:398` `sync_from_sema` (dead typed_* fields removed).
- `src/InternPool.w:85` `impl Copy for InternPool` (why pool args aren't moved).
- `src/CodegenTraits.w` `generate_default_trait_method_for_impl_ext` (push/pop
  scoping fix, was move-out/move-back).

Spec (`docs/with-specification.md`):
- §2.2 Move Semantics `:330`; drop-on-reassignment `:471`.
- §2.5 Generational Ownership `:570`; §2.5.1 `:581`; the NEW paragraph `:599`;
  §2.5.2 (static analysis is optimization not guarantee); §2.5.4 (owned = carries
  Drop = allocation buffer) `~:672`.

Decisions (`docs/decisions.md`, newest first): D20 (spec leads), D19 (batch
batteries), D18 (leak-freedom), D17 (field consume writes root / `move place`),
D16 (rvalue-uniform move), ... D14 (tiered rebuild), D6 (FnAbi single source),
D5 (share-place).

Scratchpad artifacts (`$SP`):
- `apply_moves.w` — the byte-splicer (KEEP).
- `flip-live.tsv` / `flip-live2.tsv` — move-sites partitions (regenerate fresh).
- `roundtrip.w` — nested-Vec drop fixture (leak now 0).
- `readleak.w` — 252-leak repro pre-flip; post-flip acceptance = 0.
- `scale_map_repro.w`, `map_swap_repro.w` — earlier memory-hunt repros.
- `Sema.w`/`SemaCheck.w`/`Analysis.w` (`.tools`/`.HEAD` variants) — bisection
  backups from the (resolved) 626-escalation regression; deletable.

---

## 10. Ordered next steps

1. **Fix the blocker (§3).** Apply the `restore_moved_field_lengths` atomic-pair
   fix (§3.4) — hand-trace to a contradiction FIRST. Add the `with_vec_get_ptr`
   OOB trap (§3.5) as a separate small commit; independently correct and turns
   this class from segfault into diagnostic.
2. Rebuild `:dev`; `./out/bootstrap/bin/with-stage1 check src/main.w` → expect
   `ok`. If a NEW error class appears (e.g. a loud double-free from the new free
   path), that is progress — root-cause per doctrine, don't paper over.
3. Full flip battery (§6). Drop-audit POD cells must go green; `readleak.w` → 0.
4. Commit the flip. Suggested landing units (Eric authored — NO AI trailer/
   co-author): (a) `with_vec_get_ptr` OOB trap; (b) MirLower snapshot-pair fix;
   (c) the flip (Sema arm + CodegenDispatch glue + drop-audit pins) with
   before/after drop-audit in the message; (d) the 78-site migration; (e) spec +
   doctrine (Eric-blessed; likely its own commit).
5. Reseed on the committed flip tree (§7): `:update-seed` + `:install-user`.
6. Re-measure & post to #702: battery runner peak RSS post-flip (the 8GB-budget
   acceptance test) and `readleak` = 0. Close #691.
7. Promote `apply_moves.w` → `tools/` OR fix #705 so the integrated tool works.
8. Post-flip campaign (D18 installments 2+): extern ownership contracts (an
   extern `-> str` must carry a caller-owned drop contract or be spelled
   borrowed — no allocation path outside the model); then Vale-style linear
   consumption. Each spec-first, Eric-blessed, "do the thing" procedure.

---

## 11. Landmines / hard-won lessons (don't relearn these)

- **Whitespace-significant edits**: a wrapper edit that dedents a call out of its
  guard block is legal With and silently catastrophic. `git diff` every wrapper
  edit's hunk immediately. (Cost a full day earlier — memory
  `edit-indentation-dislodge`.)
- **`with -p`/`-n` one-liners are PER-LINE**; multi-line patterns silently no-op.
  For multi-line splices use `with -e` with `with_fs_read_file`/`slice`, or Write
  the whole file.
- **Bisection verdict hygiene**: a `grep -c` printing 0 with rc=1 is ambiguous
  (clean vs. build-died). Record count + per-stage rc + wall time; an anomalous
  wall time invalidates the cell. (memory `bisection-verdict-hygiene`.)
- **Build cache across tree-state transitions**: only cold builds (`:clean` +
  `:dev`) are trustworthy across large tree changes (#700).
- **Never `git stash`** (forbidden — has destroyed work). Use `git worktree`.
  (Worktrees need `.deps` symlinked in and lack `out/gen/*` — some tool-mode
  compiles won't work in a bare worktree.)
- **Reseed = commit FIRST, then battery, then update-seed** (version stamp embeds
  git commit; install-user gate trips otherwise).
- **-O1 always, never -O0.** A bug only at -O1 is a real bug.
- **All tooling in With** — no sed/awk/python, even throwaway.
- **Debug tools before grep**: `reduce`/`analyze`/`lldb`/`--dump-*` before
  grep-crawling. The §3 root cause came from ONE lldb register dump after a day
  of theory. To get a real backtrace on a crash, set a breakpoint AT the fault
  address then `run` (a plain crash bt shows only frame#0).
- **`WITH_ALLOC_SYSTEM=1` + macOS `leaks`/`heap`** is the fastest way to see the
  With heap (freelist-over-mmap is invisible to system tools otherwise).
- **Guarantee by hand-trace before coding a fix** (Eric's standing demand). It
  disproved my first hypothesis for §3 and produced the real one.
