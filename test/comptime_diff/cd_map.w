//! expect-stdout: ok

// Comptime differential: HashMap insert/contains/len.
//
// Scoped to the comptime/runtime-CONVERGENT surface: comptime get/remove
// currently return the naked value where runtime returns Option (#665) —
// extend with get/remove round-trips when that divergence is fixed.

comptime fn map_battery(n: i32) -> i32:
    let m = HashMap[i32, i32].new()
    for i in 0..n:
        m.insert(i, i * 7)
    var acc = 0
    for i in 0..(n + 3):
        if m.contains(i):
            acc = acc + 1
        else:
            acc = acc + 50
    acc + m.len() as i32

const CT_MAP: i32 = comptime map_battery(9)

fn main:
    assert(CT_MAP == map_battery(9))
    print("ok")
