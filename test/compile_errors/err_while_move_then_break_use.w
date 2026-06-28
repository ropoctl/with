//! expect-check-fail: use of moved value

// #613: a `break` can carry a move out of the loop. `r` is moved on the break
// path, so it is moved after the loop — using it afterward is a use-after-move.
// (The move-then-break itself is accepted; only the post-loop use is rejected.)

type R { id: i32 }
impl Drop for R:
    fn drop(move self: Self):
        let _ = self.id
fn take(r: R): ()
fn make() -> R: R { id: 1 }

fn main(c: bool):
    let r = make()
    var i = 0
    while i < 10:
        if c:
            take(r)
            break
        i = i + 1
    take(r)
