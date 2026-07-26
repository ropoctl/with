//! D22-NON-COMPLIANT: future check-fail at map.clear()

fn observe_after_mutation() -> Option[i32]:
    var map: HashMap[i32, i32] = HashMap.new()
    map.insert(1, 43)
    let view = map.get(1)?
    map.clear()
    Some(view)

fn main:
    let _ = observe_after_mutation()
