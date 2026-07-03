//! expect-check-fail: cannot derive Copy for a type with non-Copy fields
type NonCopy { s: str }
@[derive(Copy)]
type Bad { n: NonCopy }
fn main:
    print("no")
