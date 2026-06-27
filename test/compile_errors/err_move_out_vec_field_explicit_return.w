//! expect-check-fail: not yet supported

// [A5] #607: explicit-return form of moving a needs-drop Vec field out of a
// struct. Keep this rejected with the tail-return and move-self forms until the
// language decision explicitly changes.

type W { tag: i32 }
impl Drop for W:
    fn drop(move self: Self):
        print_i32(self.tag)

type Holder { a: Vec[W] }

fn take(h: Holder) -> Vec[W]:
    return h.a

fn main:
    print_i32(0)
