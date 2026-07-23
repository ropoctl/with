//! D22-NON-COMPLIANT: future compile-and-run

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 46)
    let snapshot: i32 = map.get(1).unwrap()
    map.clear()
    assert(snapshot == 46)
