//! D22-NON-COMPLIANT: future compile-and-run

fn main:
    var map: HashMap[i32, Vec[i64]] = HashMap.new()
    let values: Vec[i64] = Vec.new()
    values.push(47)
    map.insert(1, move values)

    let view = map.get(1).unwrap()
    assert(view.len() == 1)  // last use: the borrow ends here
    map.clear()              // legal after the last view use

    let replacement: Vec[i64] = Vec.new()
    replacement.push(48)
    map.insert(1, move replacement)
    let owned = map.remove(1).unwrap()
    map.clear()
    assert(owned.get(0) == 48)
