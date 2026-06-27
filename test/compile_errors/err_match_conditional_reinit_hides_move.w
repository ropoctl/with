//! expect-check-fail: use of moved value

// Branch-merge soundness (#612), match form: one arm moves `r`, another
// reinitializes it. On the d==0 path `r` is consumed, so the later use is a
// use-after-move. The arm-union must mark `r` moved after the match.

type R { id: i32 }
impl Drop for R:
    fn drop(move self: Self):
        let _ = self.id
fn take(r: R): ()
fn make() -> R: R { id: 1 }
fn use2(r: R): ()

fn main(d: i32):
    var r = make()
    match d:
        0 => take(r)
        _ => r = make()
    use2(r)
