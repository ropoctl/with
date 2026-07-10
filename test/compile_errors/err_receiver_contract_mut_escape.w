//! expect-error: mut receiver is too weak; compiler effects require `move fn`

type Invalid { values: Vec[i32] }

impl Invalid:
    mut fn take() -> Invalid: self

fn main:
    var value = Invalid { values: Vec.new() }
    let _ = value.take()
