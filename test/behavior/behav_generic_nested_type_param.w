//! expect-stdout: ok

// #595: a generic fn whose param nests the type param inside another generic
// (Vec[Task[T]], Pair[Vec[T]]) must bind T structurally at codegen
// monomorphization — positional binding mis-bound T to the OUTER arg
// (T <- Task[i32]) and crashed codegen with no diagnostic (§11 generics).

type Pair[T] { a: T, b: T }

fn sum_pairs[T](items: Vec[Pair[T]]) -> i32:
    var s = 0
    for p in &items:
        s = s + 1
    s

fn first_len[T](wrapped: Pair[Vec[T]]) -> i64:
    wrapped.a.len()

fn cleanup_remaining[T](tasks: Vec[Task[T]], start: i32):
    let total = tasks.len() as i32
    var i = start
    while i < total:
        tasks.get(i).join_cleanup()
        i = i + 1

async fn child() -> i32:
    1

async fn main_task -> i32:
    let tasks: Vec[Task[i32]] = Vec.new()
    tasks.push(child())
    cleanup_remaining(tasks, 0)
    0

fn main:
    let ps: Vec[Pair[i32]] = Vec.new()
    ps.push(Pair { a: 1, b: 2 })
    ps.push(Pair { a: 3, b: 4 })
    assert(sum_pairs(ps) == 2)
    let v: Vec[i64] = Vec.new()
    v.push(9)
    let w = Pair { a: v, b: Vec.new() }
    assert(first_len(w) == 1)
    let _ = main_task().await
    print("ok")
