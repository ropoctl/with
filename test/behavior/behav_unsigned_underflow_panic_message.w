//! expect-exit: 134
//! expect-stderr: integer overflow: u64 subtraction wrapped below zero

// #630: v.len() - 1 on an empty Vec underflows usize. The panic must name
// the real cause (unsigned subtraction wrapping below zero), not just say
// "integer overflow".

fn main:
    let v: Vec[i32] = Vec.new()
    let n = v.len() - 1
    print_i64(n as i64)
