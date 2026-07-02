//! expect-check-fail: twice in one call

// #604 §21.1: the same collection cannot be passed as []mut twice in one call
// — the callee would hold two overlapping mutable views.

fn merge(a: []mut i32, b: []mut i32): ()

fn main:
    let v: Vec[i32] = Vec.new()
    v.push(1)
    merge(v, v)
