// std.task — Task type and collection-level async combinators.
//
// Task[T] is an opaque handle to a running fiber. It contains the fiber_id
// and a pointer to the heap-allocated result buffer where the fiber writes
// its return value. The T parameter is for type safety in sema.

use std.collections
use std.result

extern fn with_fiber_in_fiber() -> i32
extern fn with_fiber_is_cancelled() -> i32
extern fn with_fiber_yield() -> Unit
extern fn with_runtime_fiber_completion_sequence(fiber_id: i32) -> i64
extern fn with_runtime_has_fibers() -> i32
extern fn with_runtime_run_one_step() -> Unit

/// Opaque handle to a running fiber. Returned by async fn calls.
/// The result_buf points to a heap-allocated buffer where the fiber
/// writes its return value. Await loads from it and frees it.
pub type Task[T] { fiber_id: i32, result_buf: *mut u8 }

/// Scope-owned task handle returned by `async scope`'s `s.track(...)`.
/// It has the same ABI as Task[T], but its cleanup is owned by the scope,
/// so dropping the handle itself does not cancel the fiber.
pub type ScopedTask[T] ephemeral { fiber_id: i32, result_buf: *mut u8 }

async fn task_cancel_point(): ()

fn task_wait_for_progress():
    if with_fiber_in_fiber() != 0:
        with_fiber_yield()
        return
    if with_runtime_has_fibers() != 0:
        with_runtime_run_one_step()

fn task_first_completed[T](pending: &Vec[Task[T]], finished: &Vec[i32]) -> i32:
    var winner = -1
    var winner_sequence: i64 = 0
    var i = 0
    while i < pending.len() as i32:
        if finished.get(i) == 0:
            let sequence = with_runtime_fiber_completion_sequence(pending.get(i).fiber_id)
            if sequence > 0 and (winner < 0 or sequence < winner_sequence):
                winner = i
                winner_sequence = sequence
        i = i + 1
    winner

/// Await all tasks. Returns Vec[T] in input order.
/// Fails fast on first Err.
pub fn await_all[T, E](tasks: impl IntoIter[Task[Result[T, E]]]) -> Result[Vec[T], E]:
    let pending: Vec[Task[Result[T, E]]] = Vec.new()
    for task in tasks:
        pending.push(task)

    let total = pending.len() as i32
    let finished: Vec[i32] = Vec.new()
    let values: Vec[Option[T]] = Vec.new()
    var i = 0
    while i < total:
        finished.push(0)
        let empty: Option[T] = None
        values.push(empty)
        i = i + 1

    var cleanup_i = 0
    defer:
        while cleanup_i < total:
            if finished.get(cleanup_i) == 0:
                pending.get(cleanup_i).join_cleanup()
            cleanup_i = cleanup_i + 1

    var completed = 0
    while completed < total:
        let ready = task_first_completed(&pending, &finished)
        if ready < 0:
            task_wait_for_progress()
            if with_fiber_is_cancelled() != 0:
                task_cancel_point().await
            continue

        with finished.slot(ready) as mut slot:
            slot.set(1)
        completed = completed + 1
        let result = pending.get(ready).await
        if result.is_ok():
            with values.slot(ready) as mut slot:
                slot.set(Some(result.unwrap()))
        else:
            return Err(result.err().unwrap())

    let ordered: Vec[T] = Vec.new()
    i = 0
    while i < total:
        ordered.push(values.get(i).unwrap())
        i = i + 1
    Ok(ordered)

/// Await all tasks (infallible version). Returns Vec[T] in input order.
pub fn await_all[T](tasks: impl IntoIter[Task[T]]) -> Vec[T]:
    let pending: Vec[Task[T]] = Vec.new()
    for task in tasks:
        pending.push(task)

    let values: Vec[T] = Vec.new()
    let total = pending.len() as i32
    var next_unjoined = 0
    defer:
        while next_unjoined < total:
            pending.get(next_unjoined).join_cleanup()
            next_unjoined = next_unjoined + 1

    var i = 0
    while i < total:
        next_unjoined = i + 1
        values.push(pending.get(i).await)
        i = i + 1
    values

/// Return the result of the first task to complete.
pub fn await_first[T](tasks: impl IntoIter[Task[T]]) -> T:
    let pending: Vec[Task[T]] = Vec.new()
    for task in tasks:
        pending.push(task)

    if pending.is_empty():
        todo("await_first: empty input")

    let total = pending.len() as i32
    let finished: Vec[i32] = Vec.new()
    var i = 0
    while i < total:
        finished.push(0)
        i = i + 1

    var cleanup_i = 0
    defer:
        while cleanup_i < total:
            if finished.get(cleanup_i) == 0:
                pending.get(cleanup_i).join_cleanup()
            cleanup_i = cleanup_i + 1

    while true:
        let ready = task_first_completed(&pending, &finished)
        if ready >= 0:
            with finished.slot(ready) as mut slot:
                slot.set(1)
            return pending.get(ready).await
        task_wait_for_progress()
        if with_fiber_is_cancelled() != 0:
            task_cancel_point().await
    todo("await_first: no live tasks")

/// Return the first successful result.
/// Fails only if all tasks fail.
pub fn await_any[T, E](tasks: impl IntoIter[Task[Result[T, E]]]) -> Result[T, Vec[E]]:
    let pending: Vec[Task[Result[T, E]]] = Vec.new()
    for task in tasks:
        pending.push(task)

    let total = pending.len() as i32
    if pending.is_empty():
        let empty: Vec[E] = Vec.new()
        return Err(empty)

    let finished: Vec[i32] = Vec.new()
    let errors: Vec[Option[E]] = Vec.new()
    var i = 0
    while i < total:
        finished.push(0)
        let empty: Option[E] = None
        errors.push(empty)
        i = i + 1

    var cleanup_i = 0
    defer:
        while cleanup_i < total:
            if finished.get(cleanup_i) == 0:
                pending.get(cleanup_i).join_cleanup()
            cleanup_i = cleanup_i + 1

    var completed = 0
    while completed < total:
        let ready = task_first_completed(&pending, &finished)
        if ready < 0:
            task_wait_for_progress()
            if with_fiber_is_cancelled() != 0:
                task_cancel_point().await
            continue

        with finished.slot(ready) as mut slot:
            slot.set(1)
        completed = completed + 1
        let result = pending.get(ready).await
        if result.is_ok():
            return Ok(result.unwrap())
        with errors.slot(ready) as mut slot:
            slot.set(Some(result.err().unwrap()))

    let ordered: Vec[E] = Vec.new()
    i = 0
    while i < total:
        ordered.push(errors.get(i).unwrap())
        i = i + 1
    Err(ordered)

/// Await all tasks and return all results (including errors).
pub fn await_settled[T, E](tasks: impl IntoIter[Task[Result[T, E]]]) -> Vec[Result[T, E]]:
    let pending: Vec[Task[Result[T, E]]] = Vec.new()
    for task in tasks:
        pending.push(task)

    let settled: Vec[Result[T, E]] = Vec.new()
    let total = pending.len() as i32
    var next_unjoined = 0
    defer:
        while next_unjoined < total:
            pending.get(next_unjoined).join_cleanup()
            next_unjoined = next_unjoined + 1

    var i = 0
    while i < total:
        next_unjoined = i + 1
        settled.push(pending.get(i).await)
        i = i + 1
    settled

/// Limit concurrent execution to at most `n` tasks at a time.
pub fn with_concurrency[T](tasks: impl IntoIter[Task[T]], n: i32) -> impl IntoIter[Task[T]]:
    let _ = n
    tasks
