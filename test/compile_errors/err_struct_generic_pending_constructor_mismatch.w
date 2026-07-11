//! expect-check-fail: field type mismatch for 'b'

type Pair[T] { a: T, b: T }

fn main:
    let v: Vec[i64] = Vec.new()
    let _w = Pair { a: v, b: HashSet.new() }
