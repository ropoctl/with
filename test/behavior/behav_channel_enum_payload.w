//! expect-stdout: ok

// #671: an enum-constructor argument in statement position
// (tx.send(Some(3))) must lower with its own enum type — the ambient
// statement expectation (void) must not retype the aggregate.

enum Msg:
    Ping(i32)
    Stop

fn main:
    let (tx, rx) = chan[Option[i32]](4)
    tx.send(Some(3))
    assert(rx.recv().unwrap().unwrap() == 3)

    // #672: matching on a channel-received user enum still segfaults
    // (pre-existing runtime payload handling); recv + unwrap alone is the
    // deepest assertion that works today. Extend to a match when fixed.
    let (tx2, rx2) = chan[Msg](4)
    tx2.send(Ping(9))
    let _ = rx2.recv().unwrap()
    print("ok")
