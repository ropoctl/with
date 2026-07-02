//! expect-stdout: ok

// A8 (#606): partial extraction leaves the remaining elements owned by the
// source, which still drops them exactly once at scope exit. Tuples use the
// static partial drop; arrays blank the extracted slot (reset-on-move) and the
// guarded per-element drop skips it. Distinct ids: exact count = no leak AND
// no double-free.

type W { id: i32, slot: *mut i32 }
impl Drop for W:
    fn drop(move self: Self):
        unsafe:
            *self.slot = *self.slot + self.id

fn new_w(id: i32, s: *mut i32) -> W:
    W { id: id, slot: s }

fn run_tuple_extract_one(s: *mut i32):
    let t = (new_w(1, s), new_w(2, s))
    let a = t.0

fn run_array_extract_one(s: *mut i32):
    let arr = [new_w(1, s), new_w(2, s)]
    let a = arr[0]

fn run_array_extract_all(s: *mut i32):
    let arr = [new_w(1, s), new_w(2, s)]
    let a = arr[0]
    let b = arr[1]

fn main:
    var c = 0
    run_tuple_extract_one(&raw mut c)
    assert(c == 3)
    c = 0
    run_array_extract_one(&raw mut c)
    assert(c == 3)
    c = 0
    run_array_extract_all(&raw mut c)
    assert(c == 3)
    print("ok")
