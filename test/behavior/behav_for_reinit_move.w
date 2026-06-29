//! expect-stdout: ok

// #613: a Drop value moved out of an outer binding inside a `for` body and
// reinitialized before the back-edge is sound. The reassignment does not drop the
// already-moved value (#614). 3 loop takes + 1 final take = 4 drops.

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
    assert(drops == 4)
    print("ok")
