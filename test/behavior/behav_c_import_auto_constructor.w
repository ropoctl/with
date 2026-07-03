//! expect-stdout: ok
// §16: a c_import factory function is exposed as a type-call constructor
// (Counter.make(...)); the returned raw pointer keeps the call unsafe.
use c_import("#include <stdlib.h>\ntypedef struct Counter { int n; } Counter;\nstatic inline Counter *counter_make(int v) { Counter *c = (Counter*)malloc(sizeof(Counter)); c->n = v; return c; }\nstatic inline int counter_get(const Counter *c) { return c->n; }\n")
fn main:
    unsafe:
        let c = Counter.make(7)
        if counter_get(c) == 7: print("ok")
        else: print("bad")
