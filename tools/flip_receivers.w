// tools/flip_receivers.w — D7 enforce-first: flip a read receiver to mut where the
// build proved it mutates. Input is an errors file (one `path<TAB>line` per line,
// from the §15.2 "cannot call mutating method through a read-only place" errors);
// for each error the ENCLOSING method's `self: &Self` receiver becomes
// `mut self: Self`. Iterate build → flip until the transitive-mut closure settles.
//
//   with run tools/flip_receivers.w errs.tsv

use std.process
use Lexer
use Token

extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32

fn slice(text: str, a: i32, b: i32): text.slice(a as i64, b as i64)

// 1-based line number of a byte offset.
fn line_of(text: str, offset: i32) -> i32:
    var ln = 1
    var i = 0
    while i < offset:
        if (text.byte_at(i as i64) as i32) == 10:
            ln = ln + 1
        i = i + 1
    ln

// Flip one file: for each error line, find the enclosing `fn` and, if its receiver
// is `self: &Self`, rewrite to `mut self: Self`. Returns the number flipped.
fn flip_file(path: str, err_lines: Vec[i32]) -> i32:
    let text = unsafe { with_fs_read_file(path) }
    let tlen = text.len() as i32
    if tlen == 0:
        return 0
    var lexer = Lexer.init(text, 0)
    let tokens = lexer.tokenize()
    let n = tokens.len()

    // Collect fn decls: (fn_token_index, start_line). In source order.
    var fn_idx: Vec[i32] = Vec.new()
    var fn_line: Vec[i32] = Vec.new()
    var t = 0
    while t < n:
        if tokens.get_tag(t) == TokenKind.TK_KW_FN:
            fn_idx.push(t)
            fn_line.push(line_of(text, tokens.get_start(t)))
        t = t + 1
    let fc = fn_idx.len() as i32

    // Which fns enclose an error line: the fn whose [start_line, next_start_line)
    // range contains the error. Mark them.
    var flip: Vec[i32] = Vec.new()       // fn token indices to flip (deduped)
    var e = 0
    let ec = err_lines.len() as i32
    while e < ec:
        let el = err_lines.get(e as i64)
        var chosen = -1
        var fi = 0
        while fi < fc:
            let sl = fn_line.get(fi as i64)
            let nl = if fi + 1 < fc: fn_line.get((fi + 1) as i64) else: 2000000000
            if sl <= el and el < nl:
                chosen = fn_idx.get(fi as i64)
            fi = fi + 1
        if chosen >= 0:
            var seen = false
            var s = 0
            while s < flip.len() as i32:
                if flip.get(s as i64) == chosen:
                    seen = true
                s = s + 1
            if not seen:
                flip.push(chosen)
        e = e + 1

    // Sort the fns to flip by byte position ascending — they were collected in
    // error-line order (which is not monotonic), but the splice-apply below needs
    // ascending edits. (This was the corruption bug: unsorted → overlapping splices.)
    var fsi = 1
    while fsi < flip.len() as i32:
        var fsj = fsi
        while fsj > 0 and tokens.get_start(flip.get((fsj - 1) as i64)) > tokens.get_start(flip.get(fsj as i64)):
            let tmp = flip.get((fsj - 1) as i64)
            flip.set_i32((fsj - 1) as i64, flip.get(fsj as i64))
            flip.set_i32(fsj as i64, tmp)
            fsj = fsj - 1
        fsi = fsi + 1

    // For each fn to flip, locate `( self : & Self` and rewrite to
    // `( mut self : Self` (insert `mut `, delete the `&`).
    var starts: Vec[i32] = Vec.new()
    var ends: Vec[i32] = Vec.new()
    var repls: Vec[str] = Vec.new()
    var flipped = 0
    var f = 0
    while f < flip.len() as i32:
        let ft = flip.get(f as i64)
        // find `(` after the name (skip dotted name + optional [tp])
        var k = ft + 1
        // skip name / dotted name / type params until `(`
        while k < n and tokens.get_tag(k) != TokenKind.TK_L_PAREN and tokens.get_tag(k) != TokenKind.TK_KW_FN:
            k = k + 1
        if k >= n or tokens.get_tag(k) != TokenKind.TK_L_PAREN:
            f = f + 1
            continue
        let p = k + 1
        // must be `self : & Self`
        if p + 3 >= n:
            f = f + 1
            continue
        if tokens.get_tag(p) != TokenKind.TK_IDENT or slice(text, tokens.get_start(p), tokens.get_end(p)) != "self":
            f = f + 1
            continue
        if tokens.get_tag(p + 1) != TokenKind.TK_COLON or tokens.get_tag(p + 2) != TokenKind.TK_AMPERSAND:
            f = f + 1
            continue
        // insert `mut ` before self; delete the `&` (token p+2)
        starts.push(tokens.get_start(p))
        ends.push(tokens.get_start(p))
        repls.push("mut ")
        starts.push(tokens.get_start(p + 2))
        ends.push(tokens.get_end(p + 2))
        repls.push("")
        flipped = flipped + 1
        f = f + 1

    if flipped == 0:
        return 0
    // Edits are already ascending: fns in source order, and within each fn the
    // `mut ` insert (at `self`) precedes the `&` delete.
    let m = starts.len() as i32
    var result = ""
    var prev = 0
    var ei = 0
    while ei < m:
        result = result ++ slice(text, prev, starts.get(ei as i64)) ++ repls.get(ei as i64)
        prev = ends.get(ei as i64)
        ei = ei + 1
    result = result ++ slice(text, prev, tlen)
    let _ = unsafe { with_fs_write_file(path, result) }
    print(f"{path}: flipped {flipped}")
    flipped

fn main:
    let argv = args()
    if argv.len() < 2:
        print("usage: flip_receivers <errors.tsv>")
        exit_code(1)
    let errs = unsafe { with_fs_read_file(argv.get(1)) }
    // group error lines by file
    var files: Vec[str] = Vec.new()
    var lines_flat: Vec[i32] = Vec.new()
    var file_starts: Vec[i32] = Vec.new()   // index into a per-file collection — simpler: process incrementally
    // Simple approach: parse into parallel (file, line), then per unique file collect.
    var ef: Vec[str] = Vec.new()
    var el: Vec[i32] = Vec.new()
    let m = errs.len() as i32
    var ls = 0
    var j = 0
    while j <= m:
        if j == m or (errs.byte_at(j as i64) as i32) == 10:
            if j > ls:
                let line = slice(errs, ls, j)
                let ll = line.len() as i32
                var tab = 0
                while tab < ll and (line.byte_at(tab as i64) as i32) != 9:
                    tab = tab + 1
                if tab < ll:
                    ef.push(slice(line, 0, tab))
                    var num = 0
                    var d = tab + 1
                    while d < ll:
                        let c = line.byte_at(d as i64) as i32
                        if c >= 48 and c <= 57:
                            num = num * 10 + (c - 48)
                        d = d + 1
                    el.push(num)
            ls = j + 1
        if j == m:
            break
        j = j + 1

    // for each unique file, gather its lines and flip
    var done: Vec[str] = Vec.new()
    var total = 0
    var i = 0
    let ne = ef.len() as i32
    while i < ne:
        let fpath = ef.get(i as i64)
        var already = false
        var s = 0
        while s < done.len() as i32:
            if done.get(s as i64) == fpath:
                already = true
            s = s + 1
        if not already:
            done.push(fpath)
            var these: Vec[i32] = Vec.new()
            var k = 0
            while k < ne:
                if ef.get(k as i64) == fpath:
                    these.push(el.get(k as i64))
                k = k + 1
            total = total + flip_file(fpath, these)
        i = i + 1
    print(f"total: {total} receivers flipped to mut")
