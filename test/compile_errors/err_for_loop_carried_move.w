//! expect-check-fail: use of moved value

// #613: a Drop value moved out of an outer binding inside a `for` body, with no
// reinitialization before the back-edge, would be used moved on the next
// iteration — rejected (like Rust's "value moved in previous iteration").

type R { id: i32 }
impl Drop for R:
    fn drop(move self: Self):
        let _ = self.id
fn take(r: R): ()
fn make() -> R: R { id: 1 }

fn main:
    let r = make()
    for x in 0..3:
        take(r)
