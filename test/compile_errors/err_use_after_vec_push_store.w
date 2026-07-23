//! expect-check-fail: this parameter takes ownership of a non-Copy value

type Payload {
    values: Vec[i32],
}

fn main:
    let items: Vec[Payload] = Vec.new()
    let value = Payload { values: Vec.new() }
    items.push(value)
    print_i32(value.values.len() as i32)
