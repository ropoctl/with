//! expect-stdout: ok

// [Phase8] #357 increment 4: the owns: annotation is the explicit-annotation
// evidence source — it curates an owning constructor the compiler's tables
// don't know. getcwd(NULL, 0) mallocs the cwd string; the annotation gives it
// a COwned wrapper whose Drop frees it exactly once.

use c_import("char *getcwd(char *buf, unsigned long size);\n", owns: ["getcwd -> free"])

fn main:
    unsafe:
        let cwd = getcwd(null, 0)
        if cwd.handle() == null:
            print("bad-null")
            return
        if *(cwd.handle() as *const u8) == 0u8:
            print("bad-empty")
            return
        print("ok")
