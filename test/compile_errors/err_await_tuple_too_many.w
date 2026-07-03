//! expect-check-fail: await tuple requires between 2 and 12 tasks
async fn one -> i32: 1
fn main:
    let r = (one(),one(),one(),one(),one(),one(),one(),one(),one(),one(),one(),one(),one()).await
    print("no")
