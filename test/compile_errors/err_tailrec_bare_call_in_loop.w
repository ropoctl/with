//! expect-check-fail: not in tail position
// §9: a bare recursive call inside a `loop` body is NOT in tail position.
@[tailrec]
fn spin(n: i32) -> i32:
    var k = n
    loop:
        if k <= 0:
            break
        spin(k - 1)
        k = k - 1
    0
fn main:
    print_i32(spin(3))
