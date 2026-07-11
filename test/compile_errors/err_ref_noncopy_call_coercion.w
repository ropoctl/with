//! expect-check-fail: wrong argument type in call to 'take_buffer'

type Buffer { text: str }

fn take_buffer(value: Buffer) -> i64: value.text.len()

fn main:
    let value = Buffer { text: "owned" }
    take_buffer(&value)
