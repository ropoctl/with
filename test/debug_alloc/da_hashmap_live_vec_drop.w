//! expect-debug-alloc: leak count=0

fn main:
    var map: HashMap[i32, Vec[i64]] = HashMap.new()
    let values: Vec[i64] = Vec.new()
    values.push(7)
    values.push(9)
    map.insert(1, move values)
    assert(map.len() == 1)
