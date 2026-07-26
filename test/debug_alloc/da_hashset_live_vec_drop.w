//! expect-debug-alloc: leak count=0

fn main:
    var set: HashSet[Vec[i64]] = HashSet.new()
    let values: Vec[i64] = Vec.new()
    values.push(7)
    values.push(9)
    set.insert(move values)
    assert(set.len() == 1)
