//! expect-check-fail: wrong argument type in call to 'f'

type Buffer { text: str }

fn take_buffer(value: Buffer) -> Buffer: value
fn forward[T](f: fn(T) -> T, value: &T) -> T: f(value)

fn main:
    let value = Buffer { text: "owned" }
    let _ = forward(take_buffer, &value)
