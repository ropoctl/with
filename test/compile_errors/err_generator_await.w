//! expect-check-fail: await is not allowed in generator function
// §13: a generator (gen fn) cannot await.
async fn getv -> i32:
    1
gen fn bad -> i32:
    let x = getv().await
    yield x
fn main:
    print("no")
