//! expect-stdout: ok

// #613: a Drop value moved out of an outer binding inside a `for` body and
// reinitialized before the back-edge is sound and must compile + run.
// (Exact drop count not asserted — see #614, the pre-existing reassign-after-move
// double-drop.)

type R { id: i32, slot: *mut i32 }
impl Drop for R:
    fn drop(move self: Self):
        unsafe:
            *self.slot = *self.slot + 1
fn take(r: R): ()
fn make(slot: *mut i32) -> R: R { id: 1, slot }

fn main:
    var drops = 0
    var r = make(&raw mut drops)
    for x in 0..3:
        take(r)
        r = make(&raw mut drops)
    take(r)
    print("ok")
