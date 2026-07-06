//! skip: KNOWN BUG G1 (docs/share_place_known_gaps.md): `@[effect(handle: consume)]` on an extern fn is NOT applied to the share-place classification. `--dump-abi` shows close_external's handle as `eff=[none] value_ref_abi=1 -> SHARE-PLACE` instead of OWNED, so the declared consume is ignored and use-after is not caught. Remove this skip when fixed.
//! expect-check-fail: use of moved value

type Handle { id: i32 }
impl Handle:
    fn drop(move self: Self): ()

@[effect(handle: consume)]
extern "C" fn close_external(handle: Handle) -> Unit

fn main:
    let handle = Handle { id: 1 }
    unsafe { close_external(handle) }
    let _ = handle.id
