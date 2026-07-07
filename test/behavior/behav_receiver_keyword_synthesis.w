//! expect-stdout: ok

// D7 eliminate-self (P1): a `mut fn` / `move fn` method declared inside an
// `impl` / `extend` block synthesizes its receiver — `self` and its type are
// never written. `mut fn` == `mut self: Self`, `move fn` == `move self: Self`.
// Read-borrow methods still use the explicit `self: &Self` during the P1
// transition (P2 makes plain `fn` inside impl a read borrow).

type Counter { n: i32 }

impl Counter:
    mut fn bump(): self.n = self.n + 1
    mut fn add(k: i32): self.n = self.n + k
    move fn into_n() -> i32: self.n
    fn get(self: &Self) -> i32: self.n

extend Counter:
    move fn take -> i32: self.n          // paren-less move fn form

fn main:
    var c = Counter { n: 5 }
    c.bump()                              // mut fn: 5 -> 6
    c.add(10)                            // mut fn: 6 -> 16
    assert(c.get() == 16)                // explicit read borrow, unchanged
    let d = Counter { n: 42 }
    assert(d.into_n() == 42)             // move fn consumes d
    let e = Counter { n: 7 }
    assert(e.take() == 7)                // paren-less move fn consumes e
    print("ok")
