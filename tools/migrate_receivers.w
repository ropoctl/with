// tools/migrate_receivers.w — D7 eliminate-self receiver migrator (standalone).
//
// Rewrites in-place receiver methods declared inside impl/extend/trait blocks:
//   fn get(self: &Self) -> T    =>   fn get() -> T
//   fn set(mut self: Self, v)   =>   mut fn set(v)
//   fn take(move self: Self)    =>   move fn take()
// `self` and its type are dropped; the mode becomes a keyword before `fn`.
//
// SKIPPED (need relocation into an impl block, not yet handled): top-level dotted
// methods `fn Type.method(self: T)` — recognised by the `.` after the fn name.
// Associated / free functions (no `self` first param) are left untouched.
//
// Accurate because it tokenizes with the compiler's own Lexer, so comments and
// strings are never mistaken for code. Always re-run the gate afterward — the
// migration is only correct if the tree still builds byte-identically.
//
//   with run tools/migrate_receivers.w lib/std/rc.w lib/std/box.w ...

use std.process
use Lexer
use Token

extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32

fn migrate_file(path: str) -> i32:
    let text = unsafe { with_fs_read_file(path) }
    let tlen = text.len() as i32
    if tlen == 0:
        return 0
    var lexer = Lexer.init(text, 0)
    let tokens = lexer.tokenize()
    let n = tokens.len()

    // Edits as (start, end, replacement) byte-offset splices, in ascending order.
    var starts: Vec[i32] = Vec.new()
    var ends: Vec[i32] = Vec.new()
    var repls: Vec[str] = Vec.new()

    var i = 0
    while i < n:
        if tokens.get_tag(i) != TokenKind.TK_KW_FN:
            i = i + 1
            continue
        let fn_pos = tokens.get_start(i)
        let name_idx = i + 1
        if name_idx >= n or tokens.get_tag(name_idx) != TokenKind.TK_IDENT:
            i = i + 1
            continue
        // `fn Type.method` (dotted) → top level, needs relocation → skip.
        if name_idx + 1 < n and tokens.get_tag(name_idx + 1) == TokenKind.TK_DOT:
            i = i + 1
            continue
        // Skip optional method type params `[T, ...]`.
        var k = name_idx + 1
        if k < n and tokens.get_tag(k) == TokenKind.TK_L_BRACKET:
            var bdepth = 0
            while k < n:
                let bt = tokens.get_tag(k)
                if bt == TokenKind.TK_L_BRACKET:
                    bdepth = bdepth + 1
                else if bt == TokenKind.TK_R_BRACKET:
                    bdepth = bdepth - 1
                    if bdepth == 0:
                        k = k + 1
                        break
                k = k + 1
        if k >= n or tokens.get_tag(k) != TokenKind.TK_L_PAREN:
            i = i + 1
            continue
        // First parameter: optional mut/move, then must be `self`.
        var p = k + 1
        var mode = 0
        if p < n and tokens.get_tag(p) == TokenKind.TK_KW_MUT:
            mode = 2
            p = p + 1
        else if p < n and tokens.get_tag(p) == TokenKind.TK_KW_MOVE:
            mode = 3
            p = p + 1
        if p >= n or tokens.get_tag(p) != TokenKind.TK_IDENT:
            i = i + 1
            continue
        if text.slice(tokens.get_start(p) as i64, tokens.get_end(p) as i64) != "self":
            i = i + 1
            continue

        // Found a receiver `self`. Delete range = its first token .. end of param.
        let param_start_idx = if mode == 0: p else: p - 1
        let del_start = tokens.get_start(param_start_idx)
        var q = p + 1
        var depth = 0
        while q < n:
            let t = tokens.get_tag(q)
            if t == TokenKind.TK_L_PAREN or t == TokenKind.TK_L_BRACKET:
                depth = depth + 1
            else if t == TokenKind.TK_R_BRACKET:
                depth = depth - 1
            else if t == TokenKind.TK_R_PAREN:
                if depth == 0:
                    break
                depth = depth - 1
            else if t == TokenKind.TK_COMMA and depth == 0:
                break
            q = q + 1
        var del_end = tokens.get_start(q)
        if q < n and tokens.get_tag(q) == TokenKind.TK_COMMA:
            del_end = tokens.get_end(q)
        // Eat trailing spaces so `self: T, v` collapses to `v`, not ` v`.
        while del_end < tlen and (text.byte_at(del_end as i64) as i32) == 32:
            del_end = del_end + 1

        if mode == 2:
            starts.push(fn_pos)
            ends.push(fn_pos)
            repls.push("mut ")
        else if mode == 3:
            starts.push(fn_pos)
            ends.push(fn_pos)
            repls.push("move ")
        starts.push(del_start)
        ends.push(del_end)
        repls.push("")
        i = q

    let m = starts.len() as i32
    if m == 0:
        return 0
    // Edits are ascending (fn_pos < del_start; methods top-to-bottom): apply L→R.
    var result = ""
    var prev = 0
    var methods = 0
    for e in 0..m:
        let s = starts.get(e as i64)
        let en = ends.get(e as i64)
        let r = repls.get(e as i64)
        if r.len() == 0:
            methods = methods + 1
        result = result ++ text.slice(prev as i64, s as i64) ++ r
        prev = en
    result = result ++ text.slice(prev as i64, text.len() as i64)
    let _ = unsafe { with_fs_write_file(path, result) }
    methods

fn main:
    let argv = args()
    if argv.len() < 2:
        print("usage: migrate_receivers <file.w> [file.w ...]")
        exit_code(1)
    var total = 0
    for i in 1..argv.len() as i32:
        let path = argv.get(i as i64)
        let m = migrate_file(path)
        if m > 0:
            print(f"migrated {path}: {m} receiver methods")
        total = total + m
    print(f"total: {total} receiver methods migrated")
