//! expect-stdout: ok
// §14.7: Task.is_done() is false right after spawn and true once the scheduler
// steps the task to completion.
extern fn with_runtime_run_one_step() -> Unit
async fn compute(v: i32) -> i32:
    v + 1
fn main:
    let t = compute(41)
    assert(not t.is_done())          // false immediately after spawn
    var steps = 0
    while not t.is_done() and steps < 64:
        unsafe { with_runtime_run_one_step() }
        steps = steps + 1
    assert(t.is_done())              // true after driven to completion

    // #637: is_done stays true after .await — the reaped handle names a
    // finished task; a silent false was the one wrong answer.
    let t2 = compute(1)
    assert(t2.await == 2)
    assert(t2.is_done())
    print("ok")
