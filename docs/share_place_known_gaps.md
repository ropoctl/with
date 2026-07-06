# Share-place (D5) — known gaps

Tracked gaps in the share-place calling-convention implementation. Each has a
deterministic repro and `--dump-abi` evidence. Verify fixes with the
`/drop-audit` skill and `--dump-abi`, not by reasoning.

---

## G1 — extern `@[effect(consume)]` not applied to share-place classification

**Repro:** `test/compile_errors/err_effect_extern_consume_marks_moved.w` (currently `//! skip:`).

```with
@[effect(handle: consume)]
extern "C" fn close_external(handle: Handle) -> Unit
fn main:
    let handle = Handle { id: 1 }
    unsafe { close_external(handle) }
    let _ = handle.id            // should be use-after-move; currently accepted
```

**Fact (`with check … --dump-abi`):**
```
fn close_external  param[0] ty=… eff=[none] value_ref_abi=1 -> SHARE-PLACE
```
The declared `consume` effect is **not** on the sig (`eff=[none]`), so
`assign_share_place_abi` classifies the param SHARE-PLACE (borrow) instead of
OWNED. The consume is ignored, so the arg is treated as borrowed and use-after
is not caught.

`apply_declared_effects_to_extern_sig` (Sema.w) *does* call
`set_sig_param_effect` at decl time (SemaDecl.w:1563), yet the effect is absent
by classification time — so either the `@[effect]` pin is not parsed/attached to
the extern fn node (`fn_effect_pin_count` == 0) or the effect is reset. Worked by
accident under the old move-by-default (every param consumed regardless).

**Fix direction:** ensure `@[effect(... : consume)]` on an extern fn reaches
`sig_param_effect` before `assign_share_place_abi` runs (check pin parsing for
extern fns first). Then remove the skip; the test should again produce
`use of moved value` (or a require-move at the call).

---

## G2 — move-self receiver: Sema label vs MIR behavior divergence

`--dump-abi` reports a `move self` receiver as `value_ref_abi=1 -> SHARE-PLACE`
(because a read-only move-self body infers effect READ). The **behavior** is
correct — `lower_method_call` consumes the receiver at the call site and
`lower_fn_with_sig` drops it in the callee (verified: `/drop-audit` 0 fail) — but
the ABI *label* still says SHARE-PLACE while the drop discipline is OWNED. Per D6
(FnAbi single source of truth) the classification should match. A clean fix would
seed the move-self param's effect with `EFF_CONSUME` at the callee's body-check so
`assign_share_place_abi` classifies it OWNED, letting the caller-consume +
callee-drop fall out of the normal owned path instead of receiver-mode overrides.
Confirm any such change leaves `/drop-audit` at 0 fail and `--dump-abi` showing
`-> OWNED` for move-self.

---

## G3 — ephemeral Task double-frees when awaited through a share-place borrow

**Repro:** `test/behavior/behav_ephemeral_task_consuming_callee.w` (currently `//! skip:`).

```with
fn consume_task(task: Task[i32]) -> i32:
    task.await                       // borrows `task` (share-place), drives it
fn main:
    let first = process(&value)
    assert(consume_task(first) == 42)  // asserts pass...
    // ... then panic: "invalid free" at main's scope exit
```

`.await` does not consume the task (§14.7 — the task stays observable), so a task
passed by share-place borrow into a callee that awaits it is still owned by the
caller and dropped at the caller's scope exit. But `await` has already reaped the
task's fiber/internal state, so the caller's Task drop frees it a second time →
double free. `spec_ss14_7` (await + observe in the SAME scope) is fine; the bug is
specifically await-through-a-borrow then caller-drop.

**Fix direction:** make the Task destructor idempotent w.r.t. await — after the
fiber state has been reaped by `await`, the Task drop must free nothing (the
struct is inert but observable). This is a runtime/Task-lifecycle fix, NOT an
`await`-consume workaround (that was tried and reverted because it violates §14.7).
Verify with `--debug-alloc` (leak count == 0, no invalid free) and that
`spec_ss14_7` still passes.

