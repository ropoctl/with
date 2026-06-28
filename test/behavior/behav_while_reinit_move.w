//! expect-stdout: ok

// §2.4 / #613: a Drop value moved inside a loop and reinitialized before the
// back-edge is sound and must COMPILE (it was previously rejected outright).
// `r` is live at every back-edge and at loop exit. This fixture asserts the
// program type-checks and runs to completion.
//
// NOTE: the exact drop count is intentionally not asserted here. The §2.4
// reinit pattern currently over-counts drops by one per iteration because of a
// pre-existing, loop-independent double-drop on reassign-after-move (#614, also
// reproducible in straight-line code). Once #614 is fixed, tighten this to
// assert `drops == 4`.

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
    print("ok")
