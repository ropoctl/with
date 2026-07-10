//! expect-check-fail: cannot assign through a read-only place

type Invalid[T] { value: T }

impl[T] Invalid[T]:
    fn write(value: T): self.value = value

fn main:
    let value = Invalid { value: 0 }
    value.write(1)
