//! args: --dump-mir
//! expect-check-stdout: _4 = binop(concat, copy _1.f87
//! expect-check-stdout: _1.f87 = copy _4
//! expect-check-stdout-not: _1.f87 = str_concat_n([move _1.f87

type Acc { buf: str, name: str }

fn saved_alias -> str:
    var a = Acc { buf: "", name: "n" }
    let saved = a.buf
    a.buf = a.buf ++ "x"
    saved ++ a.buf

