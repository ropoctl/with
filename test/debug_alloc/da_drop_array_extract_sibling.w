//! expect-debug-alloc: leak count=0
// A8 (#606): extracting one element out of an array by index blanks that slot
// (reset-on-move) and keeps the array's guarded drop, so the non-extracted
// sibling is still freed exactly once — not leaked (old whole-base consume) and
// not double-freed. Covers binding, tail-return, and extract-all shapes.
extern fn with_alloc(size: i64) -> *mut u8
extern fn with_free(ptr: *mut u8) -> Unit

type W { ptr: *mut u8, slot: *mut i32 }
impl Drop for W:
    fn drop(move self: Self):
        unsafe:
            with_free(self.ptr)
            *self.slot = *self.slot + 1

fn new_w(s: *mut i32) -> W:
    unsafe { W { ptr: with_alloc(24), slot: s } }

fn run_extract_one(s: *mut i32):
    let arr = [new_w(s), new_w(s)]
    let a = arr[0]

fn run_extract_all(s: *mut i32):
    let arr = [new_w(s), new_w(s)]
    let a = arr[0]
    let b = arr[1]

fn take_first(s: *mut i32) -> W:
    let arr = [new_w(s), new_w(s)]
    arr[0]

fn run_tail_return(s: *mut i32):
    let w = take_first(s)

fn main:
    var c = 0
    run_extract_one(&raw mut c)
    run_extract_all(&raw mut c)
    run_tail_return(&raw mut c)
    print_i32(c)
