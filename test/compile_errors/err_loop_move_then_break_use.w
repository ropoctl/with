//! expect-check-fail: use of moved value

// #613: `loop` exits only via break. The break path moves `r` out, so `r` is
// moved after the loop — using it afterward is a use-after-move. The
// move-then-break itself is accepted; only the post-loop use is rejected.

type R { id: i32 }
impl Drop for R:
    fn drop(move self: Self):
        let _ = self.id
fn take(r: R): ()
fn make() -> R: R { id: 1 }

fn main(c: bool):
    let r = make()
    loop:
        if c:
            take(r)
            break
    take(r)
