//! expect-stdout: ok

// Comptime differential: every str method must produce the same answer at
// comptime and at runtime. The spec-inventory checker computed wrong sets
// for months because nothing compared the two.

comptime fn str_battery(s: str) -> i32:
    var acc = 0
    acc = acc + s.len() as i32
    if s.contains("ok"): acc = acc + 100
    if s.starts_with("in"): acc = acc + 200
    if s.ends_with("ce"): acc = acc + 400
    acc = acc + s.find("var")
    acc = acc + s.byte_at(3)
    acc = acc + s.slice(2, 8).len() as i32
    acc = acc + s.replace("a", "bb").len() as i32
    let parts = s.split("a")
    acc = acc + parts.len() as i32 * 10
    acc

const CT_STR: i32 = comptime str_battery("invariance-ok-var-dance")

fn main:
    assert(CT_STR == str_battery("invariance-ok-var-dance"))
    print("ok")
