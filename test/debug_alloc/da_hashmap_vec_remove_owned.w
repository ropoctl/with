//! expect-debug-alloc: leak count=0

fn main:
    var map: HashMap[i32, Vec[i64]] = HashMap.new()
    let values: Vec[i64] = Vec.new()
    values.push(7)
    values.push(9)
    map.insert(1, move values)
    let removed: Option[Vec[i64]] = map.remove(1)
    let owned = removed.unwrap()
    assert(owned.len() == 2)
