//! expect-check-fail: this parameter takes ownership of a non-Copy value

// D5: a plain non-Copy method argument is share-place while the method only
// reads or writes it. Returning the parameter makes it owned, so the caller
// must state the transfer explicitly.

type Payload { id: i32 }
type Runner {}

impl Runner:
    fn take(value: Payload) -> Payload: value

fn main:
    let runner = Runner {}
    let value = Payload { id: 7 }
    let _ = runner.take(value)
