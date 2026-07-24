//! expect-error: type mismatch in binding

// Raw pointers are not shared references and never receive D22 contextual Copy.
fn main:
    let value = 84
    let raw = &raw const value
    let snapshot: i32 = raw
