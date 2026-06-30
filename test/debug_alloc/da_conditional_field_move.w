//! expect-debug-alloc: leak count=0
// Slice E: a heap-backed Drop-bearing field moved conditionally out of a non-Drop
// struct. The moving path must NOT double-free h.r (the field-place niche blanks
// it and the owner's guarded per-field drop skips it); the not-moved path must
// still free it exactly once.
extern fn with_alloc(size: i64) -> *mut u8
extern fn with_free(ptr: *mut u8) -> Unit

type Resource { ptr: *mut u8, slot: *mut i32 }
impl Drop for Resource:
    fn drop(move self: Self):
        unsafe:
            with_free(self.ptr)
            *self.slot = *self.slot + 1

type Holder { r: Resource }

fn new_resource(slot: *mut i32) -> Resource:
    unsafe { Resource { ptr: with_alloc(32), slot } }

fn take(r: Resource): ()

fn run_field(cond: bool, slot: *mut i32):
    let h = Holder { r: new_resource(slot) }
    if cond:
        take(h.r)

fn main:
    var drops = 0
    run_field(true, &raw mut drops)    // moved path: no double-free on h.r
    run_field(false, &raw mut drops)   // not-moved path: h.r freed once at scope exit
    print_i32(drops)
