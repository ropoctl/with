//! expect-check-fail: mut receiver is too weak; compiler effects require `move fn`

type Owner { values: Vec[i32] }

impl Owner:
    mut fn return_receiver() -> Owner:
        self

fn main:
    var owner = Owner { values: Vec.new() }
    let escaped = owner.return_receiver()
    assert(escaped.values.len() == 0)
