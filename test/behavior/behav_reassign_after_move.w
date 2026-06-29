//! expect-stdout: ok

// #614: reassigning a Drop var whose previous value was moved out must NOT drop
// the moved-out value (it was already consumed). The drop-before-overwrite at
// `r = make()` is statically dead (r is Moved there) and is elaborated away.
// take(r1) drops r1; r = make() drops nothing; take(r2) drops r2 → 2, not 3.

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
    take(r)
    r = make(&raw mut drops)
    take(r)
    assert(drops == 2)
    print("ok")
