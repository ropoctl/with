//! expect-debug-alloc: leak count=0
extern fn with_alloc(size: i64) -> *mut u8
extern fn with_free(ptr: *mut u8) -> Unit

type W { ptr: *mut u8, slot: *mut i32 }
impl Drop for W:
    fn drop(move self: Self):
        unsafe:
            with_free(self.ptr)
            *self.slot = *self.slot + 1

type H { items: Vec[W] }

fn new_w(s: *mut i32) -> W:
    unsafe { W { ptr: with_alloc(24), slot: s } }

fn mkw(s: *mut i32) -> Vec[W]:
    let v: Vec[W] = Vec.new()
    v.push(new_w(s))
    v.push(new_w(s))
    v

fn run(s: *mut i32):
    let h = H { items: mkw(s) }
    let _ = h.items.len()

fn main:
    var c = 0
    run(&raw mut c)
    print_i32(c)
