// tools/drop_audit.w — the drop-exactly-once audit matrix (repo-committed
// successor to the lost .claude/skills/drop-audit/audit.py, rewritten in
// With per the no-foreign-tooling rule).
//
// Generates a curated cell matrix over (value shape × ownership op ×
// receiver mode × control flow), runs every cell under the native debug
// allocator, and classifies verdicts. With a baseline compiler, a cell is a
// REGRESSION iff the candidate's verdict differs from the baseline's — so
// drop-scheduling changes self-identify. Without one, verdicts compare
// against each cell's EXPECTED column only.
//
//   with run tools/drop_audit.w <candidate-with> [baseline-with]
//   with build :drop-audit          # candidate=out/release/bin/with,
//                                   # baseline=installed `with`
//
// Verdicts: PASS | LEAK | DOUBLE-FREE | VALUE-FAIL | COMPILE-FAIL | RUN-FAIL.
// POD-container cells EXPECT leak-count>0 while A5/#608 stands (the #691
// wide flip lands by flipping those expectations to PASS).
// Run BEFORE and AFTER any change to drop scheduling, ownership lowering,
// or receiver modes (CLAUDE.md gate).

use std.process

extern fn with_exec_argv_capture(argv: str, stdout_path: str, stderr_path: str, timeout_ms: i32) -> i32
extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32
extern fn with_fs_mkdir_p(path: str) -> i32

fn exec_capture(argv: str, outp: str, errp: str, timeout: i32) -> i32:
    unsafe:
        with_exec_argv_capture(argv, outp, errp, timeout)

fn read_file(path: str) -> str:
    unsafe:
        with_fs_read_file(path)

fn write_file(path: str, data: str) -> i32:
    unsafe:
        with_fs_write_file(path, data)

fn mkdirs(path: str) -> i32:
    unsafe:
        with_fs_mkdir_p(path)

fn argv4(a: str, b: str, c: str, d: str) -> str:
    a ++ "\0" ++ b ++ "\0" ++ c ++ "\0" ++ d ++ "\0"

// ── The counted resource every cell drops ────────────────────────────────
// R carries a real allocation (over/under-drop shows up as allocator leak or
// double-free) and bumps *slot by its id on drop (value-level exactly-once).

fn resource_prelude() -> str:
    "extern fn with_alloc(size: i64) -> *mut u8\n" ++
    "extern fn with_free(ptr: *mut u8) -> Unit\n" ++
    "type R { id: i32, ptr: *mut u8, slot: *mut i32 }\n" ++
    "impl Drop for R:\n" ++
    "    fn drop(move self: Self):\n" ++
    "        unsafe:\n" ++
    "            *self.slot = *self.slot + self.id\n" ++
    "            with_free(self.ptr)\n" ++
    "fn mk(id: i32, slot: *mut i32) -> R:\n" ++
    "    unsafe { R { id: id, ptr: with_alloc(16), slot: slot } }\n"

// A cell: name, generated source, expected final drop-sum printed by main,
// and whether the allocator must be clean (POD cells expect leaks, #608).
type Cell { name: str, source: str, expect_sum: i32, expect_clean: bool }

// `decls` holds the shape types and the `fn go(slot)` scenario; main just
// makes the slot, calls go, and prints the drop sum.
fn cell(name: str, decls: str, expect_sum: i32) -> Cell:
    let src = resource_prelude() ++ decls ++
        "fn main:\n" ++
        "    var drops: i32 = 0\n" ++
        "    let slot = &raw mut drops\n" ++
        "    go(slot)\n" ++
        "    print_i32(drops)\n"
    Cell { name: name, source: src, expect_sum: expect_sum, expect_clean: true }

// Shape wrappers: each returns (decls, make-expr(id), inner-access suffix).
// Scenario builders compose these; not every shape × scenario pair is
// meaningful — the matrix below curates the real cells.

fn shape_decls(shape: str) -> str:
    if shape == "field":
        return "type S { r: R, tag: i32 }\n"
    if shape == "enum":
        return "enum E:\n    Carry(R)\n    Empty\n"
    ""

fn shape_ann(shape: str) -> str:
    if shape == "option": return ": Option[R]"
    ""

fn shape_mk(shape: str, id: str) -> str:
    if shape == "bare": return "mk(" ++ id ++ ", slot)"
    if shape == "field": return "S { r: mk(" ++ id ++ ", slot), tag: 0 }"
    if shape == "tuple": return "(mk(" ++ id ++ ", slot), 7)"
    if shape == "option": return ".Some(mk(" ++ id ++ ", slot))"
    if shape == "enum": return "E.Carry(mk(" ++ id ++ ", slot))"
    "mk(" ++ id ++ ", slot)"

// ── Scenario builders ────────────────────────────────────────────────────

fn sc_scope_exit(shape: str) -> str:
    shape_decls(shape) ++ "fn go(slot: *mut i32):\n    let a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n    let _keep = 0\n"

fn sc_branch(shape: str, taken: bool) -> str:
    let flag = if taken: "true" else: "false"
    shape_decls(shape) ++
    "fn go(slot: *mut i32):\n" ++
    "    var flip = " ++ flag ++ "\n" ++
    "    if flip:\n" ++
    "        let a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "        let _k = 0\n"

fn sc_loop(shape: str) -> str:
    shape_decls(shape) ++
    "fn go(slot: *mut i32):\n" ++
    "    for i in 0..3:\n" ++
    "        let a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "        let _k = 0\n"

fn sc_move_out(shape: str) -> str:
    shape_decls(shape) ++
    "fn go(slot: *mut i32):\n" ++
    "    let a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "    let b = move a\n" ++
    "    let _k = 0\n"

fn sc_reassign(shape: str) -> str:
    shape_decls(shape) ++
    "fn go(slot: *mut i32):\n" ++
    "    var a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "    a = " ++ shape_mk(shape, "2") ++ "\n" ++
    "    let _k = 0\n"

fn sc_move_then_reassign(shape: str) -> str:
    shape_decls(shape) ++
    "fn go(slot: *mut i32):\n" ++
    "    var a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "    let b = move a\n" ++
    "    a = " ++ shape_mk(shape, "2") ++ "\n" ++
    "    let _k = 0\n"

fn sc_consume_call(shape: str) -> str:
    shape_decls(shape) ++
    "fn eat(x: " ++ (if shape == "bare": "R" else: if shape == "field": "S" else: "R") ++ "):\n" ++
    "    let y = move x\n" ++
    "    let _k = 0\n" ++
    "fn go(slot: *mut i32):\n" ++
    "    let a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "    eat(move a)\n"

fn sc_early_return(shape: str, early: bool) -> str:
    let flag = if early: "true" else: "false"
    shape_decls(shape) ++
    "fn go(slot: *mut i32):\n" ++
    "    let a" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n" ++
    "    var e = " ++ flag ++ "\n" ++
    "    if e:\n" ++
    "        return\n" ++
    "    let _k = 0\n"

fn sc_discard(shape: str) -> str:
    shape_decls(shape) ++ "fn go(slot: *mut i32):\n    let _" ++ shape_ann(shape) ++ " = " ++ shape_mk(shape, "1") ++ "\n"

fn sc_match_consume() -> str:
    shape_decls("enum") ++
    "fn go(slot: *mut i32):\n" ++
    "    let a = E.Carry(mk(1, slot))\n" ++
    "    let got = match a:\n" ++
    "        .Carry(r) => r.id\n" ++
    "        .Empty => 0\n" ++
    "    let _k = got\n"

fn sc_partial_move() -> str:
    shape_decls("field") ++
    "fn take(r: R): ()\n" ++
    "fn go(slot: *mut i32):\n" ++
    "    var s = S { r: mk(1, slot), tag: 0 }\n" ++
    "    take(s.r)\n" ++
    "    let _k = s.tag\n"

fn sc_recv_mut() -> str:
    "extend R:\n    mut fn poke(): self.id = self.id + 0\n" ++
    "fn go(slot: *mut i32):\n" ++
    "    var a = mk(1, slot)\n" ++
    "    a.poke()\n" ++
    "    a.poke()\n"

fn sc_recv_move() -> str:
    "extend R:\n    move fn into_id() -> i32: self.id\n" ++
    "fn go(slot: *mut i32):\n" ++
    "    let a = mk(1, slot)\n" ++
    "    let _got = a.into_id()\n"

fn sc_recv_replace() -> str:
    "extend R:\n    mut fn renew(slot2: *mut i32): self = mk(2, slot2)\n" ++
    "fn go(slot: *mut i32):\n" ++
    "    var a = mk(1, slot)\n" ++
    "    a.renew(slot)\n"

fn sc_vec_elem() -> str:
    "fn go(slot: *mut i32):\n" ++
    "    var v: Vec[R] = Vec.new()\n" ++
    "    v.push(mk(1, slot))\n" ++
    "    v.push(mk(2, slot))\n" ++
    "    let _k = 0\n"

// POD-container cells: pin the provisional A5/#608 status — the buffers do
// NOT free, so the allocator verdict EXPECTS leaks until #691 flips this.
fn pod_cell(name: str, body: str) -> Cell:
    let src = "fn main:\n" ++ body ++ "    print_i32(0)\n"
    Cell { name: name, source: src, expect_sum: 0, expect_clean: false }

fn build_cells() -> Vec[Cell]:
    var cells: Vec[Cell] = Vec.new()
    let shapes: Vec[str] = Vec.new()
    shapes.push("bare")
    shapes.push("field")
    shapes.push("tuple")
    shapes.push("option")
    shapes.push("enum")
    for si in 0..shapes.len() as i32:
        let sh = shapes.get(si as i64)
        cells.push(cell("scope_exit/" ++ sh, sc_scope_exit(sh), 1))
        cells.push(cell("branch_taken/" ++ sh, sc_branch(sh, true), 1))
        cells.push(cell("branch_untaken/" ++ sh, sc_branch(sh, false), 0))
        cells.push(cell("loop3/" ++ sh, sc_loop(sh), 3))
        cells.push(cell("move_out/" ++ sh, sc_move_out(sh), 1))
        cells.push(cell("reassign_over/" ++ sh, sc_reassign(sh), 3))
        cells.push(cell("move_then_reassign/" ++ sh, sc_move_then_reassign(sh), 3))
        cells.push(cell("early_return/" ++ sh, sc_early_return(sh, true), 1))
        cells.push(cell("normal_return/" ++ sh, sc_early_return(sh, false), 1))
        cells.push(cell("discard/" ++ sh, sc_discard(sh), 1))
    cells.push(cell("consume_call/bare", sc_consume_call("bare"), 1))
    cells.push(cell("consume_call/field", sc_consume_call("field"), 1))
    cells.push(cell("match_consume/enum", sc_match_consume(), 1))
    cells.push(cell("partial_move/field", sc_partial_move(), 1))
    cells.push(cell("recv_mut_borrow/bare", sc_recv_mut(), 1))
    cells.push(cell("recv_move_consume/bare", sc_recv_move(), 1))
    cells.push(cell("recv_bare_self_replace/bare", sc_recv_replace(), 3))
    cells.push(cell("vec_elem_drop/vec", sc_vec_elem(), 3))
    cells.push(pod_cell("pod_vec_scope_exit/EXPECT-LEAK", "    var v: Vec[i32] = Vec.new()\n    v.push(1)\n"))
    cells.push(pod_cell("pod_vec_reassign/EXPECT-LEAK", "    var v: Vec[i32] = Vec.new()\n    v.push(1)\n    var w: Vec[i32] = Vec.new()\n    w.push(2)\n    v = w\n"))
    cells

// ── Runner ───────────────────────────────────────────────────────────────

fn find_sub(s: str, sub: str) -> i64:
    let n = s.len()
    let m = sub.len()
    if m == 0:
        return 0
    var i: i64 = 0
    while i + m <= n:
        if s.slice(i, i + m) == sub:
            return i
        i = i + 1
    0 - 1

fn last_int_line(s: str) -> str:
    // Last non-empty stdout line = the printed drop sum.
    let lines = s.split("\n")
    var i = lines.len() as i32 - 1
    while i >= 0:
        let l = lines.get(i as i64)
        if l.len() > 0:
            return l
        i = i - 1
    ""

fn run_cell(with_bin: str, dir: str, idx: i32, source: str, expect_sum: i32, expect_clean: bool) -> str:
    let path = dir ++ f"/cell_{idx}.w"
    let _ = write_file(path, source)
    let outp = dir ++ f"/cell_{idx}.out"
    let errp = dir ++ f"/cell_{idx}.err"
    let rc = exec_capture(argv4(with_bin, "run", "--debug-alloc", path), outp, errp, 60000)
    let err = read_file(errp)
    let out = read_file(outp)
    if find_sub(err, "error:") >= 0:
        return "COMPILE-FAIL"
    if find_sub(err, "DOUBLE FREE") >= 0 or find_sub(err, "double free") >= 0:
        return "DOUBLE-FREE"
    let leaked = find_sub(err, "LEAK") >= 0
    if expect_clean and leaked:
        return "LEAK"
    if not expect_clean and not leaked:
        return "UNEXPECTED-CLEAN"
    if rc != 0 and find_sub(err, "leak count") < 0:
        return "RUN-FAIL"
    let got = last_int_line(out)
    let want = f"{expect_sum}"
    if got != want:
        return "VALUE-FAIL(got=" ++ got ++ " want=" ++ want ++ ")"
    "PASS"

fn main:
    let argv = args()
    if argv.len() < 2:
        eprint("usage: with run tools/drop_audit.w <candidate-with> [baseline-with]")
        exit_code(2)
    let candidate = argv.get(1)
    let baseline = if argv.len() as i32 >= 3: argv.get(2) else: ""
    let dir = "/tmp/drop-audit-cells"
    let _ = mkdirs(dir)
    let cells = build_cells()
    var failures = 0
    var regressions = 0
    print("cell\tcandidate" ++ (if baseline.len() > 0: "\tbaseline\tclass" else: ""))
    for i in 0..cells.len() as i32:
        let c = cells.get(i as i64)
        let cv = run_cell(candidate, dir, i, c.source, c.expect_sum, c.expect_clean)
        var row = c.name ++ "\t" ++ cv
        if baseline.len() > 0:
            let bv = run_cell(baseline, dir, i, c.source, c.expect_sum, c.expect_clean)
            let klass = if cv == bv: "same" else: "REGRESSION"
            if cv != bv:
                regressions = regressions + 1
            row = row ++ "\t" ++ bv ++ "\t" ++ klass
        if cv != "PASS":
            failures = failures + 1
        print(row)
    if baseline.len() > 0:
        print(f"drop-audit: {cells.len() as i32} cells, {failures} non-PASS, {regressions} regressions vs baseline")
        if regressions > 0:
            exit_code(1)
    else:
        print(f"drop-audit: {cells.len() as i32} cells, {failures} non-PASS")
        if failures > 0:
            exit_code(1)
    exit_code(0)
