//! expect-stdout: ok

// D5 method arguments use the same final-effect ownership decision as free
// functions: read/write parameters are share-place; consume/escape parameters
// are owned and require an explicit move/copy at the call site.

type Payload { id: i32 }
type Cell[T] { value: T }
type Holder { value: Payload }
type Runner {}

impl Runner:
    fn read(value: Payload): value.id
    fn write(value: Payload): value.id = value.id + 1
    fn transitive_write(value: Payload): self.write(value)
    fn recursive_read(value: Payload, depth: i32) -> i32:
        if depth == 0: value.id
        else: self.recursive_read(value, depth - 1)
    fn generic_read[T](value: T): ()
    fn generic_write[T](cell: Cell[T], value: T): cell.value = value
    fn take(value: Payload) -> Payload: value
    fn generic_take[T](value: T) -> T: value

fn main:
    let runner = Runner {}

    let read_value = Payload { id: 7 }
    assert(runner.read(read_value) == 7)
    assert(read_value.id == 7)

    var written = Payload { id: 10 }
    runner.write(written)
    runner.transitive_write(written)
    assert(written.id == 12)

    let recursive = Payload { id: 20 }
    assert(runner.recursive_read(recursive, 3) == 20)
    assert(recursive.id == 20)

    let holder = Holder { value: Payload { id: 30 } }
    assert(runner.read(holder.value) == 30)
    assert(holder.value.id == 30)

    let generic = Payload { id: 40 }
    runner.generic_read(generic)
    assert(generic.id == 40)

    var cell = Cell { value: Payload { id: 50 } }
    let replacement = Payload { id: 51 }
    runner.generic_write(cell, move replacement)
    assert(cell.value.id == 51)

    let owned = Payload { id: 60 }
    let taken = runner.take(move owned)
    assert(taken.id == 60)

    let generic_owned = Payload { id: 70 }
    let generic_taken = runner.generic_take(move generic_owned)
    assert(generic_taken.id == 70)

    print("ok")
