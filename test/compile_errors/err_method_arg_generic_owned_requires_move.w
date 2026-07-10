//! expect-check-fail: this parameter takes ownership of a non-Copy value

// The deferred ownership decision uses the final concrete generic-method
// effect, so generic owned parameters require the same explicit transfer.

type Payload { id: i32 }
type Runner {}

impl Runner:
    fn take[T](value: T) -> T: value

fn main:
    let runner = Runner {}
    let value = Payload { id: 7 }
    let _ = runner.take(value)
