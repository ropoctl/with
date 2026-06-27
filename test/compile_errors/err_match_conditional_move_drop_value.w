//! expect-check-fail: conditional move of Drop value requires drop-state tracking

type Resource { id: i32 }
impl Drop for Resource:
    fn drop(move self: Self):
        let _ = self.id

fn take(r: Resource): ()

fn main:
    let r = Resource { id: 1 }
    match true:
        true => take(move r)
        false => ()
