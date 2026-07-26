//! D22-NON-COMPLIANT: future check-fail at map.clear()

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 42)
    let Some(view) = map.get(1) else return
    map.clear()
    assert(view == 42)
