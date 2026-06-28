//! expect-check-fail: use of moved value

// `r` is moved inside the loop body and not reinitialized before the back-edge,
// so the next iteration would use a moved value (#613). The compiler cannot prove
// the loop runs once, so it conservatively rejects — like Rust's "value moved in
// previous iteration of loop".

type Resource { id: i32 }
impl Drop for Resource:
    fn drop(move self: Self):
        let _ = self.id

fn take(r: Resource): ()

fn main:
    let r = Resource { id: 1 }
    var keep_going = true
    while keep_going:
        take(r)
        keep_going = false
