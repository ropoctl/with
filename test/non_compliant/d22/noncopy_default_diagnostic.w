//! D22-NON-COMPLIANT: future check-fail with the normative §22.3 diagnostic

fn main:
    var jobs: HashMap[i32, Vec[i64]] = HashMap.new()
    let stored: Vec[i64] = Vec.new()
    stored.push(54)
    jobs.insert(1, move stored)

    // Must explain that ?? would need to copy a non-Copy Vec, then offer
    // .cloned(), a borrowed default, or remove only when each is applicable.
    let owned = jobs.get(1) ?? Vec.new()
    assert(owned.len() == 1)
