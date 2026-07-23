fn main:
    let values: Vec[i64] = Vec.new()
    values.push(7)
    let found: Option[&Vec[i64]] = Some(&values)
    let first = found.unwrap()
    assert(found.is_some())
    let second = found.unwrap()
    assert(first.len() == second.len())
