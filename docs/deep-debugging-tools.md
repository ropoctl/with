# Deep Debugging Tools

Status: implemented. Audience: compiler/runtime contributors.

These tools exist to stop edit/compile/trace loops. Use them to reduce the
input, inspect the exact MIR place or origin, classify allocator behavior, or
localize fixpoint nondeterminism before changing code.

## Integrated Compiler Analysis

`with analyze` is the primary cross-layer debugging surface. Unlike a standalone
scanner, it reads the compiler's live AST declarations, finalized Sema signatures
and effects, concrete specializations, `MirBody` tables, diagnostic provenance,
and the actual LLVM marshalling/prologue branches used for production codegen.

```sh
./out/stage/bin/with-stage2 analyze repro.w audit:all
./out/stage/bin/with-stage2 analyze repro.w audit:storage
./out/stage/bin/with-stage2 analyze repro.w 'matrix:name~target_fn'
./out/stage/bin/with-stage2 analyze repro.w 'path:call:main:target_fn'
./out/stage/bin/with-stage2 analyze repro.w 'closure:call:main'
./out/stage/bin/with-stage2 analyze repro.w 'lldb:kind=call,name~target_fn'
```

`audit:all` is the proof gate before an expensive build. It validates MIR shape,
types, and ownership; receiver declaration coverage and finalized contracts;
effect-flow fixed point; frozen caches and specialization bodies; frozen-phase
mutable-Sema calls; LLVM declaration pass modes; caller argument marshalling;
callee place aliasing; and the analyzer's own coverage of reachable ordinary
calls. It also runs `audit:storage`, which checks AST-indexed table bounds,
parallel start/count storage, canonical argument-node validity, and non-colliding
64-bit keys across the former 16-bit AST-node boundary. The command exits nonzero
on any violation.

Use `matrix:<query>` for root cause. A call matrix places AST/Sema/ABI/MIR and
Codegen facts in one stable table, making the first diverging layer visible. Use
`facts` or `snapshot` for the complete stable TSV schema, `summary` for counts,
and `select:<query>` for narrow machine-readable slices. Query operators are
`=`, `!=`, and `~` (substring), joined by commas.

Source-bearing facts include the source-file ID, byte `start`/`end`, line/column,
path, and declaration owner. MIR `call-argument` facts join the lowered operand,
type, effects, and ownership kind back to Sema's canonical AST argument node; for
methods the analyzer accounts for the implicit receiver argument. AST node IDs are
snapshot-local: rerun the query after any source change before using
`explain:node:<id>`.

The live MIR graph backs `path:call:<from>:<to>` and
`closure:call:<root>`. Prefer these over parsing source text. There are no legacy
semantic scanner fallbacks. If compilation stops before the needed snapshot, use
`after-mir:<request>` when available, reduce the input, or attach LLDB to the exact
compiler branch that stopped it.

Use an analysis audit directly as a reduction predicate:

```sh
./out/stage/bin/with-stage2 reduce repro.w --exit-code nonzero -- \
  ./out/stage/bin/with-stage2 analyze {file} audit:all
```

## Ownership Transfer Classification

`analyze <file> move-sites` classifies every call site where a plain non-Copy
argument binds an OWNED (consume/escape_value) parameter — the sites the
"takes ownership" diagnostic reports. It is a semantic-snapshot request: it
runs from the live Sema state even when the check fails, which is its primary
use (partitioning an error worklist, e.g. the #691 flip's, before deciding
which sites get a `move` keyword and which need design work).

```sh
./out/stage/bin/with-stage2 analyze src/main.w move-sites
```

One TSV row per site:

```
file:line:col  root  shape  spellable  liveness  loop  callee  param
```

- `shape` — `ident` (bare binding), `field` (field-path place), or `other`.
- `spellable` — whether `move <arg>` is expressible today (`ident` and
  `field` are; `other` needs the temp-local dance or a spelling extension).
- `liveness` — `last-use` when the call is the final use of the root in the
  enclosing body (a `move` cannot introduce use-after-move), `live-after`
  when later uses exist (a DESIGN site: adding `move` blanks a value the
  flow still reads — Backend.w's take-and-return class), or `unknown`.
- `loop` — `in-loop` when the call sits inside a loop body; such sites are
  conservatively design-flagged regardless of textual liveness (a
  next-iteration use is not textually "after").

The verdicts come from the checker's own use tracking, not source scanning.
`last-use` is proof the keyword is safe; `live-after` is a reading
assignment, not a verdict that the design is wrong.

## Effect Provenance

`analyze <file> 'explain:effect:<fn>[:<param>]'` prints WHY a parameter
carries each ownership-forcing effect (consume/escape_value/write), as a
chain from the queried parameter down to the seed that first set the bit —
either a direct source construct (a struct-literal move, a returned place, a
call argument) or an effect-flow edge into a callee parameter, followed
recursively until a direct seed is reached.

```sh
./out/stage/bin/with-stage2 analyze src/main.w 'explain:effect:Zcu.clear_stage_outputs:self'
```

Provenance is recorded at first-set during body checking and the effect
fixpoint; the chain names each hop's source location. Use this instead of
neutralize-bisection when a receiver demands a stronger mode than expected —
the 57-method escalation cascade in #691 was exactly one misattributed seed
plus transitive root edges, a one-query answer with provenance and an
afternoon of bisection without it. Also a semantic-snapshot request: works
on erroring inputs.

## Repro Reduction

`with reduce` minimizes a single-file repro by deleting source lines while a
predicate still holds.

```sh
./out/stage/bin/with-stage2 reduce repro.w \
    --contains "undefined variable" \
    -- ./out/stage/bin/with-stage2 check {file}
```

Options:

- `--out <path>` writes the reduced repro somewhere specific.
- `--contains <text>` requires predicate stdout/stderr to contain the text.
- `--exit-code <n|nonzero>` requires an exact exit code or any non-zero exit.

The source path must immediately follow `reduce`. Use `{file}` in the predicate
argv for the candidate path; without it, the candidate path is appended.

## MIR Place Inspection

These run from `with check` after MIR lowering:

```sh
./out/stage/bin/with-stage2 check repro.w --trace-place main:_1
./out/stage/bin/with-stage2 check repro.w --explain-mir-origin main:_1
./out/stage/bin/with-stage2 check repro.w --validate-all
./out/stage/bin/with-stage2 check repro.w --validate-ownership
```

- `--trace-place <fn:place>` prints MIR locals, statements, and terminators in
  matching functions whose text mentions the target place.
- `--explain-mir-origin <fn:item>` prints local/type/span and MIR statement or
  terminator lines that mention the target item.
- `--validate-all` runs all MIR validators and reports `validate-all: ok` or the
  first validator error.
- `--validate-ownership` runs the MIR shape checks plus ownership-specific
  place/type checks and reports `validate-ownership: ok` or the first error.

Use these before adding temporary trace prints to MIR lowering, ownership, or
codegen code.

## Source Rewrite Clients

Semantic selection stays in the compiler. The remaining source tools are thin
clients of `compiler_analyze_file`; they may use the compiler Lexer only to verify
and apply byte splices inside compiler-proven spans:

- `tools/annotate_receivers.w` applies finalized Sema receiver requirements.
- `tools/migrate_receivers.w` removes explicit receivers only from declarations
  Sema identifies as valid impl methods with matching modes.
- `tools/relocate_methods.w` relocates only Sema-identified top-level instance
  methods and verifies one semantic fact per structural rewrite.
- `tools/migrate_method_arg_moves.w` consumes structured diagnostic facts and
  exact spans; it never parses rendered stderr.

All clients preflight the complete file/path and fail before writing on missing,
duplicate, ambiguous, or mismatched facts. The removed receiver/frozen/closure,
AST-metadata, diagnostic-map, and receiver-flip scripts must not be recreated.

## Ownership And Cleanup Inspection

These commands focus on deep move/drop bugs, especially partial moves, cleanup
edges, and future runtime drop-flag work:

```sh
./out/stage/bin/with-stage2 check repro.w --trace-ownership main:_1
./out/stage/bin/with-stage2 check repro.w --dump-drop-plan
./out/stage/bin/with-stage2 check repro.w --dump-place-map
./out/stage/bin/with-stage2 check repro.w --trace-cleanup-edge 'main:bb0->bb1'
./out/stage/bin/with-stage2 check repro.w --dump-drop-flags
```

- `--trace-ownership <fn:place>` prints before/after ownership state for the
  selected place whenever MIR statements or terminators move, drop, initialize,
  or otherwise mention it. Use `fn:` with an empty place to trace all tracked
  places in that function.
- `--dump-drop-plan` prints each MIR drop site, the place being dropped, its
  state before cleanup, and whether the static plan drops, conditionally drops,
  or skips it.
- `--dump-place-map` lists each MIR place with its base local, type id, and
  normalized projection list. Use it when `_N.fK` does not mean what the source
  expression seemed to mean.
- `--trace-cleanup-edge <fn:from->to>` prints ownership state across one CFG
  edge. Both `0->1` and `bb0->bb1` are accepted. Quote this argument in shell
  commands because `>` is a redirection operator.
- `--dump-drop-flags` reports MIR-generated runtime drop flags. It prints
  `<no drop flags>` when a module does not need them; otherwise each line names
  the value local guarded by its flag local. Use this to confirm conditional
  whole-local moves are protected by a runtime flag before trusting cleanup
  behavior.

Do not infer the root cause from these reports alone. They show what MIR
believes; use `lldb` on the lowering or codegen branch to prove why it believes
that.

## Instruction-Level Root Cause

`with analyze lldb:<query>` generates breakpoints from live facts, but LLDB is
still the authority for the exact failing instruction and runtime condition. Stop
at the function/branch, inspect registers and the backtrace, and disassemble when
source-level stepping hides an inlined checked operation.

The resolved-call storage failure is the model: LLDB proved that
`resolved_call_arg_key(call_node, idx)` shifted an `i32` node by 16 bits and hit
checked overflow at node 37418; even without the panic it would collide above
65535. The repair separated start/count maps and changed default-argument keys to
an `i64` 32/32 representation. `audit:storage` now preserves that proof. A trace
count or error table would only have characterized the failure; the debugger named
the exact function, instruction, operands, and invalid capacity assumption.

### Batch LLDB on compiler binaries (proven recipes)

Hard-won specifics for `lldb --batch` against `-O1 -g` With binaries:

- Symbol names are dotted: `breakpoint set -n Codegen.gen_module`, not
  `gen_module`. A bare-name breakpoint reports `no locations (pending)` and
  the run proceeds uninstrumented.
- Function-body breakpoints on our `-O1` binaries can resolve yet never fire
  (line-table skew); LLVM C API symbols (`LLVMAddFunction`,
  `LLVMTargetMachineEmitToFile`, `LLVMBuildAlloca`) are reliable anchors with
  ABI-stable argument registers.
- Our DWARF has no variable info (`frame variable` fails with "no variable
  information"); read entry-register args at non-inlined symbol entries, and
  treat `[inlined]` frame line attributions as unreliable.
- `register read` transcribes inside breakpoint command lists;
  `memory read` with a `$reg` address does not — do memory dumps at the
  final stop from the `-o` command stream instead.
- To classify an `llvm::Type*` without expression evaluation:
  `memory read -s1 -fx -c 4 '$x1+8'` — the byte at +8 is the TypeID
  (7 = void on LLVM 22). `CreateAlloca` of a void type is what a
  `DataLayout::getTypeSizeInBits` `brk #1` under an alloca backtrace means.
- A silent SIGTRAP (exit 133, no output) is either an LLVM release-build
  `brk` or a `switch undef` miscompile detonating; the backtrace
  discriminates in one run — LLVM frames mean invalid IR construction,
  pure With frames mean the silent-undef class (#653).

## Fixpoint Diff

When `with build :fixpoint` fails, generate a focused byte-level report:

```sh
with build :fixpoint-diff
cat out/fixpoint-diff/report.txt
```

Or run it directly:

```sh
./out/stage/bin/with-stage2 fixpoint-diff \
    out/stage/bin/with-stage2-fixpoint.o \
    out/stage/bin/with-stage3-fixpoint.o
```

The report names file sizes, whether the size differs, the first differing byte
offset, and a small byte window around the mismatch. It does not yet attribute
the difference to an object symbol; use `llvm-nm`, `otool`, or `lldb` after the
byte offset narrows the search.

## Debug Allocator Filters

The native debug allocator remains the first tool for drop, lifetime,
double-free, use-after-free, and leak bugs:

```sh
./out/stage/bin/with-stage2 run --debug-alloc repro.w
./out/stage/bin/with-stage2 run --debug-alloc --debug-alloc-filter=non-root repro.w
```

Leak filters:

- `all` shows every live allocation.
- `non-root` suppresses allocations marked as process-lifetime roots.
- `roots` shows only marked roots.

Runtime code can mark an allocation as an intentional root with
`with_debug_alloc_mark_root(ptr, reason_ptr, reason_len)`. Debug-allocator
fixtures can set `//! debug-alloc-filter: non-root` to assert the non-root leak
view instead of raw process-lifetime noise.

## Verification Targets

```sh
with build :deep-debug-tool-tests
with build :debug-alloc-tests
with build :fixpoint-diff
```

The full `with build :test` target includes `:deep-debug-tool-tests`; run the
focused targets while developing changes to these tools.
