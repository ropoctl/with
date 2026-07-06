//! expect-stdout: 3

// §D5 share-place: a function may return a view derived from EITHER of two
// by-value params on different paths — both are pointers to the caller's live
// places, so either returned view is valid. Previously rejected; share-place
// makes it correct. (Prints 1 + 2 = 3.)

type Buf { data: i32 }

fn choose_view(a: Buf, b: Buf, take_a: bool) -> &i32:
    if take_a:
        return &a.data
    return &b.data

fn main:
    let a = Buf { data: 1 }
    let b = Buf { data: 2 }
    print_i32(*choose_view(a, b, true) + *choose_view(a, b, false))
