//! expect-error: type mismatch in binding

// A transparent carrier preserves the exact &Vec payload. Context cannot copy
// a non-Copy pointee into an owned Vec.
fn main:
    let values: Vec[i32] = Vec.new()
    let carrier: Option[&Vec[i32]] = Some(&values)
    let view = carrier.unwrap()
    let owned: Vec[i32] = view
