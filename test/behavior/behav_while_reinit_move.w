//! expect-stdout: ok

// §2.4 / #613: a Drop value moved inside a loop and reinitialized before the
// back-edge is sound (it was previously rejected outright). `r` is live at every
// back-edge and at loop exit. Each iteration drops the OLD value exactly once
// (via the consuming `take`); the reassignment does NOT drop the already-moved
// value (#614, the drop-elaboration "Dead" arm). 3 loop takes + 1 final take = 4.

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
    var i = 0
    while i < 3:
        take(r)
        r = make(&raw mut drops)
        i = i + 1
    take(r)
    assert(drops == 4)
    print("ok")
