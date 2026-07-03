//! expect-check-fail: ?? default value must match the unwrapped payload type
fn main:
    let o: Option[i32] = Some(1)
    let x = o ?? "str"
    print("no")
