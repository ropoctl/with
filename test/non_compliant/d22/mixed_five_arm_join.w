//! D22-NON-COMPLIANT: future compile-and-run

fn main:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(0, 50)
    map.insert(1, 51)
    map.insert(2, 52)
    map.insert(3, 53)

    let pick = 2
    let anchored = match pick:
        0 => map.get(0).unwrap()
        1 => map.get(1).unwrap()
        2 => map.get(2).unwrap()
        3 => map.get(3).unwrap()
        _ => 99

    let owned_first = match pick:
        0 => 99
        1 => map.get(1).unwrap()
        2 => map.get(2).unwrap()
        3 => map.get(3).unwrap()
        _ => map.get(0).unwrap()

    let pinned: i32 = match pick:
        0 => map.get(0).unwrap()
        1 => map.get(1).unwrap()
        2 => map.get(2).unwrap()
        3 => map.get(3).unwrap()
        _ => map.get(0).unwrap()

    map.clear()
    assert(anchored == 52)
    assert(owned_first == 52)
    assert(pinned == 52)
