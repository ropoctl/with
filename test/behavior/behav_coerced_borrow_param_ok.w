//! expect-stdout: hi!
// §5.2 (#626): a `&T` field coercing a PARAMETER (which outlives the call) is
// safe — the origin is not a dying local.
type View ephemeral { s: &str }
fn f(src: str) -> View:
    View { s: src }
fn main:
    let s = "hi"
    let v = f(s)
    print(v.s ++ "!")
