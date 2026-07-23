//! expect-check-fail: return type mismatch

// SUPERSEDED BY D22 (implementation in progress): return is now an owned-demand
// context, so this program must eventually compile by materializing i32. Keep
// this active old verdict only until the approved implementation flips it into
// a must-compile fixture; it is not language doctrine.

fn copied(reference: &i32) -> i32: reference

fn main:
    let value: i32 = 42
    let _ = copied(&value)
