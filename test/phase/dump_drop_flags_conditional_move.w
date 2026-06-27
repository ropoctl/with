//! args: --dump-drop-flags
//! expect-check-stdout: drop-flags module
//! expect-check-stdout: guards

type Resource { id: i32 }
impl Drop for Resource:
    fn drop(move self: Self):
        let _ = self.id

fn take(r: Resource): ()

fn main:
    let r = Resource { id: 1 }
    if true:
        take(r)
