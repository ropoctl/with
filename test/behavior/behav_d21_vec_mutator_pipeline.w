//! expect-stdout: ok

fn accepts_unit(_value: Unit):
    let _ = _value

fn main:
    var v: Vec[i32] = Vec.new()
    accepts_unit(v.push(1))
    v |> push(2) |> clear() |> push(40) |> push(2)
    assert(v.len() == 2)
    assert(v.get(0) == 40)
    assert(v.get(1) == 2)

    v.push(v.get(0))
    v |> push(v.get(0))
    assert(v.len() == 4)
    assert(v.get(2) == 40)
    assert(v.get(3) == 40)

    let built: Vec[i32] = Vec.new() |> push(20) |> push(22)
    assert(built.len() == 2)
    assert(built.get(0) + built.get(1) == 42)
    print("ok")
