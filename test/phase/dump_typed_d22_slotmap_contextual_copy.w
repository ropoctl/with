//! args: --dump-typed
//! expect-check-stdout: typed contextual-copy-adjustments=3
//! expect-check-stdout: bind view: &i32
//! expect-check-stdout: bind snapshot: i32
//! expect-check-stdout: exact=&i32 owned=i32 target=i32 post=identity
//! expect-check-stdout-not: bind view: i32

// SlotMap is D22's already-uniform keyed lookup control. This fixture asks only
// Sema questions; its ownership/drop behavior remains a Stage 5 gate.
fn main:
    var map: SlotMap[i32] = SlotMap.new()
    let handle = map.insert(88)
    let view = map.get(handle).unwrap()
    let snapshot: i32 = view
    assert(snapshot == 88)
