//! skip: KNOWN BUG G3 (docs/share_place_known_gaps.md): an ephemeral Task awaited through a share-place borrow (consume_task borrows `task`, awaits it) double-frees at the caller's scope exit — `await` reaps the fiber state, then the caller's Task drop frees it again. Asserts pass ("ok") then it panics with "invalid free" on cleanup. Needs an idempotent Task drop-after-await (runtime), not an await-consume workaround (that violates §14.7 observe-after-await). Remove this skip when fixed.
//! expect-stdout: ok

async fn process(value: &i32) -> i32:
    *value + 1

fn consume_task(task: Task[i32]) -> i32:
    task.await

fn forward_to_consumer(task: Task[i32]) -> i32:
    consume_task(task)

fn main:
    let value = 41
    let first = process(&value)
    assert(consume_task(first) == 42)

    let second = process(&value)
    assert(forward_to_consumer(second) == 42)
    print("ok")
