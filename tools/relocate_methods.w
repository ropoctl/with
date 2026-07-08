// tools/relocate_methods.w — D7 P3: relocate top-level instance methods into impl
// blocks. A top-level `fn Type.method(self: ...)` is "static by location" under
// D7; to become an implicit-self instance method it must move into an
// `impl Type:` (or `impl[Tp] Type[Args]:`) block, dropping `self` for the keyword
// form. Associated functions (`fn Type.make()` — no `self`) stay at top level.
//
// Uses the compiler's Lexer for token-accurate identification. Comments are
// whitespace to the lexer, so gaps between methods carry no tokens: a same-target
// run of methods (only comments/blanks between them) groups under one impl header,
// and their inter-method comments are re-indented into the block. A method whose
// type params are not all bound by its receiver (e.g. `Vec.map[T, U]` on `Vec[T]`)
// is SKIPPED and reported, never silently mis-moved.
//
//   with run tools/relocate_methods.w --report src/Foo.w      # dry-run, list targets
//   with run tools/relocate_methods.w src/Foo.w lib/std/x.w   # rewrite in place

use std.process
use Lexer
use Token

extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32

// 0-based column of a byte offset (distance from the start of its line, 10 = '\n').
fn col_of(text: str, offset: i32):
    var j = offset - 1
    while j >= 0 and (text.byte_at(j as i64) as i32) != 10:
        j = j - 1
    offset - (j + 1)

fn slice(text: str, a: i32, b: i32): text.slice(a as i64, b as i64)

// Prefix `pad` to every non-empty line of `text` (blank lines stay blank).
fn reindent(text: str, pad: str):
    var parts: Vec[str] = Vec.new()
    let m = text.len() as i32
    var line_start = 0
    var i = 0
    while i < m:
        if (text.byte_at(i as i64) as i32) == 10:
            if i > line_start:
                parts.push(pad)
                parts.push(slice(text, line_start, i))
            parts.push("\n")
            line_start = i + 1
        i = i + 1
    if m > line_start:
        parts.push(pad)
        parts.push(slice(text, line_start, m))
    parts.join("")

// Count top-level comma-separated segments in the bytes of a `[...]` group text.
fn count_args(inner: str) -> i32:
    let m = inner.len() as i32
    if m == 0:
        return 0
    var depth = 0
    var segs = 1
    var i = 0
    while i < m:
        let c = inner.byte_at(i as i64) as i32
        if c == 91:            // [
            depth = depth + 1
        else if c == 93:       // ]
            depth = depth - 1
        else if c == 44 and depth == 0:   // , at top level
            segs = segs + 1
        i = i + 1
    segs

fn relocate_file(path: str, report_only: bool) -> i32:
    let text = unsafe { with_fs_read_file(path) }
    let tlen = text.len() as i32
    if tlen == 0:
        return 0
    var lexer = Lexer.init(text, 0)
    let tokens = lexer.tokenize()
    let n = tokens.len()

    var chunks: Vec[str] = Vec.new()
    var cursor = 0             // bytes emitted up to here
    var open_header = ""       // current open impl group header ("" = none)
    var count = 0
    var skipped = 0

    var i = 0
    while i < n:
        // Blank lines emit a NEWLINE token at column 0 — skip them; they are not
        // decls and must not reset an open impl group.
        if tokens.get_tag(i) == TokenKind.TK_NEWLINE:
            i = i + 1
            continue
        if col_of(text, tokens.get_start(i)) != 0:
            i = i + 1
            continue
        // i is a top-level decl start (column 0). Classify it.
        var fn_tok = i
        var vis_pub = false
        if tokens.get_tag(i) == TokenKind.TK_KW_PUB:
            vis_pub = true
            fn_tok = i + 1
        var reloc = false
        if fn_tok < n and tokens.get_tag(fn_tok) == TokenKind.TK_KW_FN:
            let ti = fn_tok + 1
            if ti + 2 < n and tokens.get_tag(ti) == TokenKind.TK_IDENT and tokens.get_tag(ti + 1) == TokenKind.TK_DOT and tokens.get_tag(ti + 2) == TokenKind.TK_IDENT:
                reloc = true

        if not reloc:
            // Non-relocatable top-level decl → close any open impl group. Its text
            // stays at column 0 (emitted with the next gap or the tail).
            open_header = ""
            i = i + 1
            continue

        // ---- extract the method ----
        let decl_start = if vis_pub: tokens.get_start(i) else: tokens.get_start(fn_tok)
        let fn_pos = tokens.get_start(fn_tok)
        let type_idx = fn_tok + 1
        let type_start = tokens.get_start(type_idx)
        let type_name = slice(text, type_start, tokens.get_end(type_idx))
        let name_start = tokens.get_start(type_idx + 2)

        // optional method type params `[...]`, then `(`
        var k = type_idx + 3
        var has_tp = false
        var tp_open = 0
        var tp_inner_a = 0
        var tp_inner_b = 0
        if k < n and tokens.get_tag(k) == TokenKind.TK_L_BRACKET:
            has_tp = true
            tp_open = tokens.get_start(k)
            tp_inner_a = tokens.get_end(k)
            var bd = 0
            while k < n:
                let bt = tokens.get_tag(k)
                if bt == TokenKind.TK_L_BRACKET:
                    bd = bd + 1
                else if bt == TokenKind.TK_R_BRACKET:
                    bd = bd - 1
                    if bd == 0:
                        tp_inner_b = tokens.get_start(k)
                        k = k + 1
                        break
                k = k + 1
        if k >= n or tokens.get_tag(k) != TokenKind.TK_L_PAREN:
            open_header = ""
            i = i + 1
            continue
        let paren_pos = tokens.get_start(k)
        let tp_start = if has_tp: tp_open else: paren_pos
        let tp_end = paren_pos

        // first param must be `[mut|move] self`
        var fp = k + 1
        var mode_kw = ""
        var param_start = tokens.get_start(fp)
        var self_tok = fp
        if fp < n and tokens.get_tag(fp) == TokenKind.TK_KW_MUT:
            mode_kw = "mut "
            self_tok = fp + 1
        else if fp < n and tokens.get_tag(fp) == TokenKind.TK_KW_MOVE:
            mode_kw = "move "
            self_tok = fp + 1
        if self_tok >= n or tokens.get_tag(self_tok) != TokenKind.TK_IDENT or slice(text, tokens.get_start(self_tok), tokens.get_end(self_tok)) != "self":
            open_header = ""
            i = i + 1
            continue

        // receiver type: after `self :` to top-level `,`/`)`
        var rt = self_tok + 1
        if rt < n and tokens.get_tag(rt) == TokenKind.TK_COLON:
            rt = rt + 1
        let recv_start = tokens.get_start(rt)
        var depth = 0
        var q = rt
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
        var recv_type = slice(text, recv_start, tokens.get_start(q))
        // strip a leading `&` (borrow) — the target type is the same
        var rti = 0
        let rlen = recv_type.len() as i32
        while rti < rlen and (recv_type.byte_at(rti as i64) as i32) == 38:   // &
            rti = rti + 1
        while rti < rlen and (recv_type.byte_at(rti as i64) as i32) == 32:   // space
            rti = rti + 1
        let target = slice(recv_type, rti, rlen)

        // self param deletion end
        var self_del_end = tokens.get_start(q)
        if q < n and tokens.get_tag(q) == TokenKind.TK_COMMA:
            self_del_end = tokens.get_end(q)
            while self_del_end < tlen and (text.byte_at(self_del_end as i64) as i32) == 32:
                self_del_end = self_del_end + 1

        // method extent: up to the next column-0 token, skipping trailing NEWLINE
        // tokens so body_end lands just after the method's last content line.
        var j = fn_tok + 1
        while j < n and (tokens.get_tag(j) == TokenKind.TK_NEWLINE or col_of(text, tokens.get_start(j)) != 0):
            j = j + 1
        var last = j - 1
        while last > fn_tok and tokens.get_tag(last) == TokenKind.TK_NEWLINE:
            last = last - 1
        var body_end = tokens.get_end(last)
        while body_end < tlen and (text.byte_at(body_end as i64) as i32) != 10:
            body_end = body_end + 1
        if body_end < tlen:
            body_end = body_end + 1

        // build the impl header. Method type params must all be bound by the
        // receiver: require count(tparams) == count(target args), else skip+report.
        var tp_decl = ""
        if has_tp:
            tp_decl = slice(text, tp_open, tp_inner_b + 1)   // `[K: Ord, V]`
        var ok = true
        if has_tp:
            let tp_inner = slice(text, tp_inner_a, tp_inner_b)
            // target args: inside the target's own `[...]`
            let tl = target.len() as i32
            var ta = 0
            while ta < tl and (target.byte_at(ta as i64) as i32) != 91:  // find [
                ta = ta + 1
            if ta >= tl:
                ok = false
            else:
                var tb = tl - 1
                while tb > ta and (target.byte_at(tb as i64) as i32) != 93:  // find ]
                    tb = tb - 1
                let target_args = slice(target, ta + 1, tb)
                if count_args(tp_inner) != count_args(target_args):
                    ok = false
        let header = f"impl{tp_decl} {target}:"

        if report_only:
            let flag = if ok: "" else: "  [SKIP: complex type params]"
            print(f"  {type_name}.{slice(text, name_start, tokens.get_end(type_idx + 2))}  {header}{flag}")
            if ok:
                count = count + 1
            else:
                skipped = skipped + 1
            i = j
            continue

        if not ok:
            skipped = skipped + 1
            open_header = ""     // leave this method at top level; it ends any group
            i = j
            continue

        // ---- emit ----
        let gap = slice(text, cursor, decl_start)
        if open_header == header:
            chunks.push(reindent(gap, "    "))     // inter-method comments go inside
        else:
            chunks.push(gap)                        // leading comments at column 0
            chunks.push(header)
            chunks.push("\n")
            open_header = header

        // transformed method: pub? + mode + `fn ` + name + `(` + params-after-self + body
        var mparts: Vec[str] = Vec.new()
        mparts.push(slice(text, decl_start, fn_pos))   // `pub ` or ``
        mparts.push(mode_kw)                           // `mut `/`move `/``
        mparts.push(slice(text, fn_pos, type_start))   // `fn `
        mparts.push(slice(text, name_start, tp_start)) // method name
        mparts.push(slice(text, tp_end, param_start))  // `(`
        mparts.push(slice(text, self_del_end, body_end))  // rest (params, ret, body)
        chunks.push(reindent(mparts.join(""), "    "))

        cursor = body_end
        count = count + 1
        i = j

    if report_only:
        if count > 0 or skipped > 0:
            print(f"{path}: {count} relocatable, {skipped} skipped")
        return count

    if count == 0:
        return 0
    chunks.push(slice(text, cursor, tlen))    // tail
    let _ = unsafe { with_fs_write_file(path, chunks.join("")) }
    if skipped > 0:
        print(f"{path}: relocated {count}, SKIPPED {skipped} (complex type params — left at top level)")
    else:
        print(f"{path}: relocated {count}")
    count

fn main:
    let argv = args()
    if argv.len() < 2:
        print("usage: relocate_methods [--report] <file.w> [file.w ...]")
        exit_code(1)
    var report_only = false
    var start = 1
    if argv.get(1) == "--report":
        report_only = true
        start = 2
    var total = 0
    for i in start..argv.len() as i32:
        total = total + relocate_file(argv.get(i as i64), report_only)
    print(f"total: {total} methods")
