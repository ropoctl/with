//! D22-NON-COMPLIANT: future check-fail at primary.clear()

fn main:
    var primary: HashMap[i32, i32] = HashMap.new()
    var fallback: HashMap[i32, i32] = HashMap.new()
    primary.insert(1, 44)
    fallback.insert(1, 45)

    let view = primary.get(1) ?? fallback.get(1).unwrap()
    primary.clear()
    assert(view == 44)
