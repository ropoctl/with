//! expect-check-fail: type mismatch in binding

fn main:
    let value: i32 = 42
    let reference = &value
    let copied: i32 = reference
