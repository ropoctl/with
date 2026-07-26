//! D22-NON-COMPLIANT: future check-fail at map.clear()

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 41)
    let view = map.get(1).unwrap()
    map.clear()
    assert(view == 41)
