//! args: --dump-mir
//! expect-check-stdout: _6 = binop(concat, copy _1.f87
//! expect-check-stdout: _1.f87 = copy _6
//! expect-check-stdout-not: _1.f87 = str_concat_n([move _1.f87

type Acc { buf: str, name: str }

fn touch(a: &Acc) -> i32:
    if a.buf.len() > 100:
        return 1
    0

fn call_taints_base -> str:
    var a = Acc { buf: "", name: "n" }
    let _ = touch(a)
    a.buf = a.buf ++ "x"
    a.buf

