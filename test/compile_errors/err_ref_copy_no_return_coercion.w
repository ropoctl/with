//! expect-check-fail: return type mismatch

fn copied(reference: &i32) -> i32: reference

fn main:
    let value: i32 = 42
    let _ = copied(&value)
