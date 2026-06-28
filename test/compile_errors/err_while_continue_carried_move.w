//! expect-check-fail: use of moved value

// #613: a `continue` jumps to the back-edge. `r` is moved before the continue
// and not reinitialized, so the next iteration would use it moved — rejected.

type R { id: i32 }
impl Drop for R:
    fn drop(move self: Self):
        let _ = self.id
fn take(r: R): ()
fn make() -> R: R { id: 1 }

fn main(c: bool):
    let r = make()
    var i = 0
    while i < 3:
        take(r)
        i = i + 1
        if c:
            continue
