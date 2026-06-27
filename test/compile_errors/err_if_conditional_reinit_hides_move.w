//! expect-check-fail: use of moved value

// Branch-merge soundness (#612): one branch moves `r`, the other reinitializes it.
// On the d==true path `r` is consumed by `take`, so the later use is a
// use-after-move. The move-state union must mark `r` moved after the if.

type R { id: i32 }
impl Drop for R:
    fn drop(move self: Self):
        let _ = self.id
fn take(r: R): ()
fn make() -> R: R { id: 1 }
fn use2(r: R): ()

fn main(d: bool):
    var r = make()
    if d:
        take(r)
    else:
        r = make()
    use2(r)
