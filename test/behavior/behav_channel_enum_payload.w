//! expect-stdout: ok

// §14.15: recv() returns the element directly (blocking); enum elements
// round-trip intact — including None, whose delivery is distinguishable
// from "empty" because the runtime signals empty via status, not value.
// Also pins #671 (constructor args in statement position).

enum Msg:
    Ping(i32)
    Stop

fn main:
    let (tx, rx) = chan[Option[i32]](4)
    tx.send(None)
    assert(rx.recv().is_none())
    tx.send(Some(3))
    assert(rx.recv().unwrap() == 3)

    let (tx2, rx2) = chan[Msg](4)
    tx2.send(Ping(9))
    match rx2.recv():
        Ping(v) => assert(v == 9)
        Stop => assert(false)
    print("ok")
