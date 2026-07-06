//! expect-stdout: ok

async fn process(value: &i32) -> i32:
    *value + 1

fn consume_task(task: Task[i32]) -> i32:
    task.await

fn forward_to_consumer(task: Task[i32]) -> i32:
    consume_task(move task)

fn main:
    let value = 41
    let first = process(&value)
    assert(consume_task(move first) == 42)

    let second = process(&value)
    assert(forward_to_consumer(move second) == 42)
    print("ok")
