// tools/annotate_receivers.w — D7 enforce-first Pass 1: give every by-value
// `self: Type` receiver an explicit mode, read from a compiler-produced map.
//
// The compiler's enforcement emits `[D7-recv Type.method <mode>]` with the mode it
// inferred from the finalized self effect. This tool consumes that map and rewrites
// each by-value receiver in place (NO relocation — that is Pass 2):
//   read  `fn`      →  self: &Self
//   mut   `mut fn`  →  mut self: <Type>   (prepend `mut `)
//   move  `move fn` →  move self: <Type>  (prepend `move `)
// A method not in the map, or already `&`/`mut`/`move`, is left untouched. The
// inference misses mutation through a sub-call, so some read annotations will be
// wrong — the build surfaces those (`read-only place`) to flip to `mut`.
//
//   with run tools/annotate_receivers.w modemap.tsv src/Foo.w lib/std/x.w ...

use std.process
use Lexer
use Token

extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32

fn slice(text: str, a: i32, b: i32): text.slice(a as i64, b as i64)

// Look up `key` (a `Type.method`) in the tab-separated map lines; return its mode
// ("fn"/"mut fn"/"move fn") or "" if absent.
fn lookup(keys: Vec[str], modes: Vec[str], key: str) -> str:
    var i = 0
    let n = keys.len() as i32
    while i < n:
        if keys.get(i as i64) == key:
            return modes.get(i as i64)
        i = i + 1
    ""

fn annotate_file(path: str, keys: Vec[str], modes: Vec[str]) -> i32:
    let text = unsafe { with_fs_read_file(path) }
    let tlen = text.len() as i32
    if tlen == 0:
        return 0
    var lexer = Lexer.init(text, 0)
    let tokens = lexer.tokenize()
    let n = tokens.len()

    // (start, end, replacement) splices, ascending.
    var starts: Vec[i32] = Vec.new()
    var ends: Vec[i32] = Vec.new()
    var repls: Vec[str] = Vec.new()
    var count = 0

    var i = 0
    while i < n:
        if tokens.get_tag(i) != TokenKind.TK_KW_FN:
            i = i + 1
            continue
        let name_idx = i + 1
        if name_idx >= n or tokens.get_tag(name_idx) != TokenKind.TK_IDENT:
            i = i + 1
            continue
        // Determine the `Type.method` key. Dotted top-level: `fn Type.method`.
        // In-block: `fn method` — key is `<enclosingType>.method`, which we don't
        // track here (those are already keyword-form after Pass 2), so require the
        // dotted form.
        if name_idx + 2 >= n or tokens.get_tag(name_idx + 1) != TokenKind.TK_DOT or tokens.get_tag(name_idx + 2) != TokenKind.TK_IDENT:
            i = i + 1
            continue
        let type_name = slice(text, tokens.get_start(name_idx), tokens.get_end(name_idx))
        let method_name = slice(text, tokens.get_start(name_idx + 2), tokens.get_end(name_idx + 2))
        let key = type_name ++ "." ++ method_name

        // skip optional method type params, reach `(`
        var k = name_idx + 3
        if k < n and tokens.get_tag(k) == TokenKind.TK_L_BRACKET:
            var bd = 0
            while k < n:
                let bt = tokens.get_tag(k)
                if bt == TokenKind.TK_L_BRACKET:
                    bd = bd + 1
                else if bt == TokenKind.TK_R_BRACKET:
                    bd = bd - 1
                    if bd == 0:
                        k = k + 1
                        break
                k = k + 1
        if k >= n or tokens.get_tag(k) != TokenKind.TK_L_PAREN:
            i = i + 1
            continue

        // first param must be a MODE-LESS `self` (no mut/move keyword)
        let p = k + 1
        if p >= n or tokens.get_tag(p) != TokenKind.TK_IDENT or slice(text, tokens.get_start(p), tokens.get_end(p)) != "self":
            i = i + 1
            continue
        // must be `self :` with a value type (skip if next is `,`/`)` — malformed)
        var ct = p + 1
        if ct >= n or tokens.get_tag(ct) != TokenKind.TK_COLON:
            i = i + 1
            continue
        // receiver type spans after `:` to the top-level `,` or `)`
        var tstart = ct + 1
        // if the type already begins with `&`, it is a read borrow — skip
        if tstart < n and tokens.get_tag(tstart) == TokenKind.TK_AMPERSAND:
            i = i + 1
            continue
        var depth = 0
        var q = tstart
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

        let mode = lookup(keys, modes, key)
        if mode == "":
            i = i + 1
            continue
        if mode == "fn":
            // replace `self: <Type>` with `self: &Self`: keep `self`, replace type.
            starts.push(tokens.get_start(tstart))
            ends.push(tokens.get_start(q))
            repls.push("&Self")
        else if mode == "mut fn":
            starts.push(tokens.get_start(p))
            ends.push(tokens.get_start(p))
            repls.push("mut ")
        else if mode == "move fn":
            starts.push(tokens.get_start(p))
            ends.push(tokens.get_start(p))
            repls.push("move ")
        count = count + 1
        i = q + 1

    let m = starts.len() as i32
    if m == 0:
        return 0
    var result = ""
    var prev = 0
    for e in 0..m:
        result = result ++ slice(text, prev, starts.get(e as i64)) ++ repls.get(e as i64)
        prev = ends.get(e as i64)
    result = result ++ slice(text, prev, tlen)
    let _ = unsafe { with_fs_write_file(path, result) }
    print(f"{path}: annotated {count}")
    count

fn main:
    let argv = args()
    if argv.len() < 3:
        print("usage: annotate_receivers <modemap.tsv> <file.w> [file.w ...]")
        exit_code(1)
    // load the map
    let map_text = unsafe { with_fs_read_file(argv.get(1)) }
    var keys: Vec[str] = Vec.new()
    var modes: Vec[str] = Vec.new()
    let ml = map_text.len() as i32
    var ls = 0
    var j = 0
    while j <= ml:
        if j == ml or (map_text.byte_at(j as i64) as i32) == 10:
            if j > ls:
                let line = slice(map_text, ls, j)
                // split on tab
                let ll = line.len() as i32
                var tab = 0
                while tab < ll and (line.byte_at(tab as i64) as i32) != 9:
                    tab = tab + 1
                if tab < ll:
                    keys.push(slice(line, 0, tab))
                    modes.push(slice(line, tab + 1, ll))
            ls = j + 1
        if j == ml:
            break
        j = j + 1
    print(f"loaded {keys.len() as i32} mode entries")

    var total = 0
    for a in 2..argv.len() as i32:
        total = total + annotate_file(argv.get(a as i64), keys, modes)
    print(f"total: {total} receivers annotated")
