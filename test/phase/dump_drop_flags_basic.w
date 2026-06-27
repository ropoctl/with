//! args: --dump-drop-flags --no-prelude
//! expect-check-stdout: drop-flags module
//! expect-check-stdout: <no drop flags>

fn main:
    let x = 1
    let _ = x
