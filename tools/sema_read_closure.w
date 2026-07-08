// tools/sema_read_closure.w — D7 receiver-mode convergence analyzer.
//
// The type-query hubs (is_copy, type_needs_drop, has_drop_method, ...) are called
// through `&Sema` read-borrows in MirLower/Codegen (roots). A read (`&Self`) method
// can only call read methods on self, so the WHOLE transitive self-call closure of
// the roots MUST be read. This tool computes that closure statically and answers:
//   1. Which Sema methods are in the must-be-read set?
//   2. Of those, which are still `mut`/by-value (need converting)?
//   3. WHY — each method's direct mut sources (field writes, mutating calls, intern),
//      classified fixable (handle-copy / Vec->HashSet / frozen-lookup / interior-mut
//      context) vs GENUINE (real state mutation that CANNOT be made read).
//   4. Ranked shared mut sources (which few fields to fix = biggest blast radius).
//   5. The verdict: any GENUINE blocker => the refactor is NOT purely mechanical.
//
//   with run tools/sema_read_closure.w src/Sema.w src/SemaCheck.w src/SemaDecl.w \
//       src/SemaDiag.w src/TypeLayout.w src/ComptimeEval.w src/ComptimeTransform.w \
//       src/MirLower.w src/Codegen.w src/CCodegen.w src/Mir.w src/AsyncLower.w
//
// Extra args (quote the `>` so the shell does not treat it as redirection):
//   "cut:CALLER>CALLEE"  remove that self-edge before closure (does severing it help?)
//   "sink:METHOD"        reverse-reach: which frozen roots re-enter METHOD
//   "path:A>B"           print one self-call chain A -> ... -> B (is the edge real?)
//
// Token-accurate (uses the compiler's own Lexer); heuristics noted inline.
// KEY RESULT (2026-07-08): Sema's query surface and its type-checker are ONE SCC
// (is_copy <-> check_expr), so no receiver-mode 2-coloring exists. See project notes.

use std.process
use Lexer
use Token

extern fn with_fs_read_file(path: str) -> str

fn slice(text: str, a: i32, b: i32): text.slice(a as i64, b as i64)

// byte index of '>' in s, or -1
fn find_gt(s: str) -> i32:
    var i = 0
    let n = s.len() as i32
    while i < n:
        if (s.byte_at(i as i64) as i32) == 62:
            return i
        i = i + 1
    -1

// Receiver-mutating methods (called as `self.field.<m>(`) that mutate the receiver.
fn is_mut_method(s: str) -> bool:
    s == "insert" or s == "push" or s == "pop" or s == "remove" or s == "clear" or s == "set" or s == "set_i32" or s == "set_i64" or s == "set_str" or s == "reserve" or s == "truncate" or s == "resize" or s == "extend" or s == "swap_remove" or s == "swap" or s == "retain" or s == "sort" or s == "append" or s == "put" or s == "push_front" or s == "pop_front"

// Classify a field by its name (role in the interior-mut recipe).
fn field_role(name: str) -> str:
    if name.contains("subst"):
        return "context"
    if name.contains("visit") or name.contains("guard") or name.contains("stack"):
        return "guard"
    if name.contains("cache") or name.contains("memo") or name.ends_with("_map"):
        return "cache"
    "other"

// mut-source kinds: 0 = field write (self.f = / +=), 1 = mutating call (self.f.m()),
//                   2 = intern (self.pool_intern(...)).
fn fix_label(kind: i32, ty: str, role: str) -> str:
    if kind == 2:
        return "intern->frozen-lookup [fixable]"
    if kind == 1:
        if ty.starts_with("HashMap") or ty.starts_with("HashSet"):
            return "handle-copy [fixable]"
        if ty.starts_with("Vec"):
            if role == "guard":
                return "Vec->HashSet [fixable]"
            return "GENUINE: Vec data mutation"
        return f"GENUINE: mutcall on {ty}"
    // kind 0: field write
    if role == "context":
        return "interior-mut context [needs work]"
    "GENUINE: field assignment"

fn is_genuine(label: str): label.starts_with("GENUINE")

fn mode_name(m: i32) -> str:
    if m == 0:
        return "read"
    if m == 1:
        return "MUT"
    if m == 2:
        return "MOVE"
    if m == 3:
        return "byval"
    if m == 4:
        return "assoc"
    "?"

fn main:
    let argv = args()
    if argv.len() < 2:
        print("usage: sema_read_closure <file.w> [file.w ...]")
        exit_code(1)

    // Sema struct fields: name -> first type token (for classification).
    var fldtype: HashMap[str, str] = HashMap.new()
    // &Sema read-borrow binding names (params/fields typed `&Sema`) => roots.
    var rb: HashMap[str, i32] = HashMap.new()
    // method registry
    var mname: Vec[str] = Vec.new()
    var mmode: Vec[i32] = Vec.new()
    var mfile: Vec[str] = Vec.new()
    var midx: HashMap[str, i32] = HashMap.new()
    // internal self-call edges (caller idx -> callee name, resolved later)
    var e_from: Vec[i32] = Vec.new()
    var e_toname: Vec[str] = Vec.new()
    // mut sources (method idx, field, kind)
    var ms_m: Vec[i32] = Vec.new()
    var ms_field: Vec[str] = Vec.new()
    var ms_kind: Vec[i32] = Vec.new()
    // roots (callee names reached through a &Sema binding)
    var root_list: Vec[str] = Vec.new()
    var root_seen: HashMap[str, i32] = HashMap.new()
    // severed edges: argv entries `cut:CALLER>CALLEE` remove that self-edge before
    // closure (to prove "cut this re-entrancy => the closure collapses").
    var cuts: HashMap[str, i32] = HashMap.new()
    // sinks: argv entries `sink:METHOD` => reverse-reachability report (which roots
    // reach this method = the frozen entry points that re-enter it).
    var sinks: Vec[str] = Vec.new()
    // paths: argv entries `path:A>B` => print one self-call path from A to B (verify
    // an edge chain is real).
    var path_a: Vec[str] = Vec.new()
    var path_b: Vec[str] = Vec.new()

    let nfiles = argv.len() as i32
    var ca = 1
    while ca < nfiles:
        let arg = argv.get(ca as i64)
        if arg.starts_with("cut:"):
            cuts.insert(arg.slice(4 as i64, arg.len()), 1)
        else if arg.starts_with("sink:"):
            sinks.push(arg.slice(5 as i64, arg.len()))
        else if arg.starts_with("path:"):
            let spec = arg.slice(5 as i64, arg.len())
            let gt = find_gt(spec)
            if gt > 0:
                path_a.push(spec.slice(0 as i64, gt as i64))
                path_b.push(spec.slice((gt + 1) as i64, spec.len()))
        ca = ca + 1

    // ============ PASS A: collect struct fields + &Sema binding names ============
    var fi = 1
    while fi < nfiles:
        let path = argv.get(fi as i64)
        if path.starts_with("cut:") or path.starts_with("sink:") or path.starts_with("path:"):
            fi = fi + 1
            continue
        let text = unsafe { with_fs_read_file(path) }
        let tlen = text.len() as i32
        if tlen == 0:
            fi = fi + 1
            continue
        var lexer = Lexer.init(text, 0)
        let tokens = lexer.tokenize()
        let n = tokens.len()
        var i = 0
        while i < n:
            let tag = tokens.get_tag(i)
            // &Sema binding: IDENT `:` `&` `Sema`
            let is_bind = tag == TokenKind.TK_IDENT and i + 3 < n and tokens.get_tag(i + 1) == TokenKind.TK_COLON and tokens.get_tag(i + 2) == TokenKind.TK_AMPERSAND and tokens.get_tag(i + 3) == TokenKind.TK_IDENT
            if is_bind and slice(text, tokens.get_start(i + 3), tokens.get_end(i + 3)) == "Sema":
                rb.insert(slice(text, tokens.get_start(i), tokens.get_end(i)), 1)
            // Sema struct: `type` `Sema` `{`
            let is_semastruct = tag == TokenKind.TK_KW_TYPE and i + 2 < n and tokens.get_tag(i + 1) == TokenKind.TK_IDENT and tokens.get_tag(i + 2) == TokenKind.TK_L_BRACE
            if is_semastruct and slice(text, tokens.get_start(i + 1), tokens.get_end(i + 1)) == "Sema":
                var j = i + 3
                var depth = 1
                while j < n and depth > 0:
                    let jt = tokens.get_tag(j)
                    let is_field = depth == 1 and jt == TokenKind.TK_IDENT and j + 2 < n and tokens.get_tag(j + 1) == TokenKind.TK_COLON
                    if jt == TokenKind.TK_L_BRACE:
                        depth = depth + 1
                        j = j + 1
                    else if jt == TokenKind.TK_R_BRACE:
                        depth = depth - 1
                        j = j + 1
                    else if is_field:
                        let fname = slice(text, tokens.get_start(j), tokens.get_end(j))
                        var typ = "?"
                        if tokens.get_tag(j + 2) == TokenKind.TK_IDENT:
                            typ = slice(text, tokens.get_start(j + 2), tokens.get_end(j + 2))
                        fldtype.insert(fname, typ)
                        j = j + 2
                    else:
                        j = j + 1
                i = j
                continue
            i = i + 1
        fi = fi + 1
    print(f"pass A: {rb.len() as i32} &Sema binding names, {fldtype.len() as i32} Sema fields")

    // ============ PASS B: methods, edges, mut sources, roots ============
    fi = 1
    while fi < nfiles:
        let path = argv.get(fi as i64)
        if path.starts_with("cut:") or path.starts_with("sink:") or path.starts_with("path:"):
            fi = fi + 1
            continue
        let text = unsafe { with_fs_read_file(path) }
        let tlen = text.len() as i32
        if tlen == 0:
            fi = fi + 1
            continue
        // Frozen consumer files: they hold `sema` as `&Sema` (they never own a Sema),
        // so every `sema.M(` / `self.sema.M(` there is a genuine read-borrow root.
        // (ComptimeEval owns a by-value Sema copy — excluded, else its mutations pollute.)
        let frozen = path.ends_with("MirLower.w") or path.ends_with("Codegen.w") or path.ends_with("CCodegen.w") or path.ends_with("Mir.w") or path.ends_with("AsyncLower.w")
        var lexer = Lexer.init(text, 0)
        let tokens = lexer.tokenize()
        let n = tokens.len()
        var cur = -1   // current Sema instance method index, or -1
        var i = 0
        while i < n:
            let tag = tokens.get_tag(i)

            // ---- fn decl boundary ----
            if tag == TokenKind.TK_KW_FN:
                let named = i + 1 < n and tokens.get_tag(i + 1) == TokenKind.TK_IDENT
                let is_sema = named and slice(text, tokens.get_start(i + 1), tokens.get_end(i + 1)) == "Sema" and i + 3 < n and tokens.get_tag(i + 2) == TokenKind.TK_DOT and tokens.get_tag(i + 3) == TokenKind.TK_IDENT
                if is_sema:
                    let name = slice(text, tokens.get_start(i + 3), tokens.get_end(i + 3))
                    var idx = -1
                    if midx.contains(name):
                        idx = midx.get(name).unwrap()
                    else:
                        idx = mname.len() as i32
                        mname.push(name)
                        mmode.push(-1)
                        mfile.push(path)
                        midx.insert(name, idx)
                    cur = idx
                    // reach `(`: skip optional `[...]` generic params
                    var k = i + 4
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
                    var mode = 4  // assoc unless we find a self receiver
                    if k < n and tokens.get_tag(k) == TokenKind.TK_L_PAREN:
                        let p = k + 1
                        let is_mut = p + 1 < n and tokens.get_tag(p) == TokenKind.TK_KW_MUT and tokens.get_tag(p + 1) == TokenKind.TK_IDENT and slice(text, tokens.get_start(p + 1), tokens.get_end(p + 1)) == "self"
                        let is_move = p + 1 < n and tokens.get_tag(p) == TokenKind.TK_KW_MOVE and tokens.get_tag(p + 1) == TokenKind.TK_IDENT and slice(text, tokens.get_start(p + 1), tokens.get_end(p + 1)) == "self"
                        let is_self = p < n and tokens.get_tag(p) == TokenKind.TK_IDENT and slice(text, tokens.get_start(p), tokens.get_end(p)) == "self"
                        let is_ref = is_self and p + 2 < n and tokens.get_tag(p + 1) == TokenKind.TK_COLON and tokens.get_tag(p + 2) == TokenKind.TK_AMPERSAND
                        if is_mut:
                            mode = 1
                        else if is_move:
                            mode = 2
                        else if is_ref:
                            mode = 0
                        else if is_self:
                            mode = 3
                    if mmode.get(idx as i64) == -1:
                        mmode.set_i32(idx as i64, mode)
                    i = i + 4
                    continue
                else if named:
                    // some other named decl — leave the Sema method body
                    cur = -1
                i = i + 1
                continue

            // ---- root: `sema . METHOD (` in a frozen consumer file (sema is &Sema) ----
            let is_call = tag == TokenKind.TK_IDENT and i + 3 < n and tokens.get_tag(i + 1) == TokenKind.TK_DOT and tokens.get_tag(i + 2) == TokenKind.TK_IDENT and tokens.get_tag(i + 3) == TokenKind.TK_L_PAREN
            if frozen and is_call and slice(text, tokens.get_start(i), tokens.get_end(i)) == "sema":
                let callee = slice(text, tokens.get_start(i + 2), tokens.get_end(i + 2))
                if not root_seen.contains(callee):
                    root_seen.insert(callee, 1)
                    root_list.push(callee)

            // ---- internal edges + mut sources: `self . X ...` inside a Sema method ----
            let is_selfdot = cur >= 0 and tag == TokenKind.TK_IDENT and i + 2 < n and tokens.get_tag(i + 1) == TokenKind.TK_DOT and tokens.get_tag(i + 2) == TokenKind.TK_IDENT
            if is_selfdot and slice(text, tokens.get_start(i), tokens.get_end(i)) == "self":
                let x = slice(text, tokens.get_start(i + 2), tokens.get_end(i + 2))
                let after = i + 3
                let atag = if after < n: tokens.get_tag(after) else: -1
                let is_fieldcall = atag == TokenKind.TK_DOT and after + 2 < n and tokens.get_tag(after + 1) == TokenKind.TK_IDENT and tokens.get_tag(after + 2) == TokenKind.TK_L_PAREN
                let is_write = atag == TokenKind.TK_EQ or atag == TokenKind.TK_PLUS_EQ or atag == TokenKind.TK_MINUS_EQ or atag == TokenKind.TK_STAR_EQ or atag == TokenKind.TK_SLASH_EQ
                if atag == TokenKind.TK_L_PAREN:
                    // self.X(...) — internal call edge
                    e_from.push(cur)
                    e_toname.push(x)
                    if x == "pool_intern":
                        ms_m.push(cur)
                        ms_field.push("pool_intern")
                        ms_kind.push(2)
                else if is_fieldcall and is_mut_method(slice(text, tokens.get_start(after + 1), tokens.get_end(after + 1))):
                    ms_m.push(cur)
                    ms_field.push(x)
                    ms_kind.push(1)
                else if is_write:
                    ms_m.push(cur)
                    ms_field.push(x)
                    ms_kind.push(0)
            i = i + 1
        fi = fi + 1

    let nm = mname.len() as i32
    print(f"pass B: {nm} Sema methods, {e_from.len() as i32} self-edges, {ms_m.len() as i32} mut-source records, {root_list.len() as i32} root callees")

    // ============ resolve edges ============
    var e_to: Vec[i32] = Vec.new()
    let ne = e_from.len() as i32
    var ncut = 0
    var ei = 0
    while ei < ne:
        let nm2 = e_toname.get(ei as i64)
        let fromname = mname.get(e_from.get(ei as i64) as i64)
        let cutkey = fromname ++ ">" ++ nm2
        if cuts.contains(cutkey):
            e_to.push(-1)
            ncut = ncut + 1
        else if midx.contains(nm2):
            e_to.push(midx.get(nm2).unwrap())
        else:
            e_to.push(-1)
        ei = ei + 1
    if cuts.len() > 0:
        print(f"severed {ncut} edge instances matching {cuts.len() as i32} cut spec(s)")

    // ============ closure: reach = methods that MUST be read ============
    // pred[m] = predecessor on the self-call path from a root (-2 = root, -1 = unset)
    var pred: Vec[i32] = Vec.new()
    var pp = 0
    while pp < nm:
        pred.push(-1)
        pp = pp + 1
    var reach: HashMap[i32, i32] = HashMap.new()
    var roots_present = 0
    var ri = 0
    let nr = root_list.len() as i32
    while ri < nr:
        let rn = root_list.get(ri as i64)
        if midx.contains(rn):
            let rix = midx.get(rn).unwrap()
            reach.insert(rix, 1)
            pred.set_i32(rix as i64, -2)
            roots_present = roots_present + 1
        ri = ri + 1
    var changed = true
    while changed:
        changed = false
        var i = 0
        while i < ne:
            let f = e_from.get(i as i64)
            let t = e_to.get(i as i64)
            if t >= 0 and reach.contains(f) and (not reach.contains(t)):
                reach.insert(t, 1)
                pred.set_i32(t as i64, f)
                changed = true
            i = i + 1

    // read-set members + mode breakdown
    var readset: Vec[i32] = Vec.new()
    var c_read = 0
    var c_mut = 0
    var c_move = 0
    var c_byval = 0
    var c_assoc = 0
    var mi = 0
    while mi < nm:
        if reach.contains(mi):
            readset.push(mi)
            let md = mmode.get(mi as i64)
            if md == 0:
                c_read = c_read + 1
            else if md == 1:
                c_mut = c_mut + 1
            else if md == 2:
                c_move = c_move + 1
            else if md == 3:
                c_byval = c_byval + 1
            else if md == 4:
                c_assoc = c_assoc + 1
        mi = mi + 1
    let nrs = readset.len() as i32

    print("")
    print("================ MUST-BE-READ CLOSURE ================")
    print(f"roots found in registry : {roots_present} / {nr} distinct root callees")
    print(f"read-set size           : {nrs} methods")
    print(f"  already read (&Self)   : {c_read}")
    print(f"  MUT (need convert)     : {c_mut}")
    print(f"  MOVE (cannot be read!) : {c_move}")
    print(f"  by-value (need mode)   : {c_byval}")
    print(f"  assoc (no receiver)    : {c_assoc}")

    // ============ per-read-set-method mut sources; find genuine blockers ============
    print("")
    print("================ GENUINE BLOCKERS (can a read-set method NOT be read?) ================")
    var mutator: HashMap[i32, i32] = HashMap.new()   // read-set methods with a genuine mut source
    var nblock = 0
    let nms = ms_m.len() as i32
    var rk = 0
    while rk < nrs:
        let m = readset.get(rk as i64)
        let md = mmode.get(m as i64)
        var printed_hdr = false
        if md == 2:
            mutator.insert(m, 1)
            print(f"  [MOVE] {mname.get(m as i64)}  ({mfile.get(m as i64)}) — move receiver in read path")
            nblock = nblock + 1
            printed_hdr = true
        var si = 0
        while si < nms:
            if ms_m.get(si as i64) == m:
                let fld = ms_field.get(si as i64)
                let kind = ms_kind.get(si as i64)
                var typ = "?"
                if fldtype.contains(fld):
                    typ = fldtype.get(fld).unwrap()
                let role = field_role(fld)
                let label = fix_label(kind, typ, role)
                if is_genuine(label):
                    mutator.insert(m, 1)
                    if not printed_hdr:
                        print(f"  [{mode_name(md)}] {mname.get(m as i64)}  ({mfile.get(m as i64)})")
                        // trace one self-call path from a root to this method
                        var path: Vec[str] = Vec.new()
                        var cnode = m
                        var guard = 0
                        while cnode >= 0 and guard < 24:
                            path.push(mname.get(cnode as i64))
                            let pc = pred.get(cnode as i64)
                            if pc < 0:
                                break
                            cnode = pc
                            guard = guard + 1
                        var ps = ""
                        var pth = path.len() as i32 - 1
                        while pth >= 0:
                            ps = ps ++ path.get(pth as i64)
                            if pth > 0:
                                ps = ps ++ " -> "
                            pth = pth - 1
                        print(f"        via: {ps}")
                        printed_hdr = true
                        nblock = nblock + 1
                    print(f"        self.{fld}: {typ}  -> {label}")
            si = si + 1
        rk = rk + 1
    if nblock == 0:
        print("  (none) — the read-closure is MECHANICALLY achievable: every mut source")
        print("  in the read-set is fixable (handle-copy / Vec->HashSet / frozen-lookup /")
        print("  interior-mut context). No type query genuinely mutates compiler state.")
    else:
        print(f"  => {nblock} method(s) carry a GENUINE mut source or move mode.")

    // ============ ranked shared mut sources (roots to fix) ============
    var rank_names: Vec[str] = Vec.new()
    var rank_counts: Vec[i32] = Vec.new()
    var rank_idx: HashMap[str, i32] = HashMap.new()
    var seen_fm: HashMap[str, i32] = HashMap.new()
    var si2 = 0
    while si2 < nms:
        let m = ms_m.get(si2 as i64)
        if reach.contains(m):
            let fld = ms_field.get(si2 as i64)
            let key = f"{fld}#{m}"
            if not seen_fm.contains(key):
                seen_fm.insert(key, 1)
                if rank_idx.contains(fld):
                    let ridx = rank_idx.get(fld).unwrap()
                    rank_counts.set_i32(ridx as i64, rank_counts.get(ridx as i64) + 1)
                else:
                    let ridx = rank_names.len() as i32
                    rank_names.push(fld)
                    rank_counts.push(1)
                    rank_idx.insert(fld, ridx)
        si2 = si2 + 1
    // insertion sort by count desc
    let nrank = rank_names.len() as i32
    var order: Vec[i32] = Vec.new()
    var oi = 0
    while oi < nrank:
        order.push(oi)
        oi = oi + 1
    var a = 1
    while a < nrank:
        let ov = order.get(a as i64)
        let cv = rank_counts.get(ov as i64)
        var b = a - 1
        while b >= 0 and rank_counts.get(order.get(b as i64) as i64) < cv:
            order.set_i32((b + 1) as i64, order.get(b as i64))
            b = b - 1
        order.set_i32((b + 1) as i64, ov)
        a = a + 1
    print("")
    print("================ RANKED SHARED MUT SOURCES (count = read-set methods blocked) ================")
    var pr = 0
    while pr < nrank and pr < 40:
        let ov = order.get(pr as i64)
        let fld = rank_names.get(ov as i64)
        let cnt = rank_counts.get(ov as i64)
        var typ = "?"
        if fldtype.contains(fld):
            typ = fldtype.get(fld).unwrap()
        let role = field_role(fld)
        var lbl = "review (write or Vec-data)"
        if fld == "pool_intern":
            lbl = "intern->frozen-lookup [fixable]"
        else if role == "context":
            lbl = "interior-mut context [needs work]"
        else if typ.starts_with("HashMap") or typ.starts_with("HashSet"):
            lbl = "handle-copy [fixable]"
        else if typ.starts_with("Vec") and role == "guard":
            lbl = "Vec->HashSet [fixable]"
        print(f"  {cnt}\tself.{fld}: {typ}  [{role}]  -> {lbl}")
        pr = pr + 1

    // ============ frontier edges: pure query method -> genuine mutator ============
    // These are the exact call sites where a would-be-read method calls a genuine
    // mutator. Severing/replacing these (with pure memoized lookups) disentangles the
    // query layer from the mutating checker. This is the surgical fix list.
    print("")
    print("================ FRONTIER EDGES (pure read-set method -> genuine mutator) ================")
    print("  (sever/replace these to disentangle the query layer; count = distinct edges)")
    var fedge_seen: HashMap[str, i32] = HashMap.new()
    var nfront = 0
    var fe = 0
    while fe < ne:
        let f = e_from.get(fe as i64)
        let t = e_to.get(fe as i64)
        let f_in = reach.contains(f) and (not mutator.contains(f))
        let t_mut = t >= 0 and mutator.contains(t)
        if f_in and t_mut:
            let ekey = f"{f}>{t}"
            if not fedge_seen.contains(ekey):
                fedge_seen.insert(ekey, 1)
                print(f"  {mname.get(f as i64)} -> {mname.get(t as i64)}")
                nfront = nfront + 1
        fe = fe + 1
    print(f"  => {nfront} frontier edge(s)")

    // ============ reverse reachability: which roots reach a sink method? ============
    // For each `sink:METHOD`, the frozen entry points that re-enter it are the roots
    // among its ancestors in the self-call graph. Those are the call sites to sever.
    var sk = 0
    let nsink = sinks.len() as i32
    while sk < nsink:
        let sname = sinks.get(sk as i64)
        print("")
        print(f"================ REVERSE REACH: roots that reach {sname} ================")
        if not midx.contains(sname):
            print("  (method not found)")
            sk = sk + 1
            continue
        let sidx = midx.get(sname).unwrap()
        var anc: HashMap[i32, i32] = HashMap.new()
        anc.insert(sidx, 1)
        var achanged = true
        while achanged:
            achanged = false
            var i = 0
            while i < ne:
                let f = e_from.get(i as i64)
                let t = e_to.get(i as i64)
                if t >= 0 and anc.contains(t) and (not anc.contains(f)):
                    anc.insert(f, 1)
                    achanged = true
                i = i + 1
        var nroots_reach = 0
        var ai = 0
        while ai < nm:
            let is_root = pred.get(ai as i64) == -2
            if is_root and anc.contains(ai):
                print(f"  root: {mname.get(ai as i64)}  ({mfile.get(ai as i64)})  [{mode_name(mmode.get(ai as i64))}]")
                nroots_reach = nroots_reach + 1
            ai = ai + 1
        print(f"  => {nroots_reach} frozen root(s) re-enter {sname}")
        sk = sk + 1

    // ============ path finder: one self-call chain from A to B ============
    var qi = 0
    let nq = path_a.len() as i32
    while qi < nq:
        let aname = path_a.get(qi as i64)
        let bname = path_b.get(qi as i64)
        print("")
        print(f"================ PATH: {aname} -> ... -> {bname} ================")
        if (not midx.contains(aname)) or (not midx.contains(bname)):
            print("  (endpoint not found)")
            qi = qi + 1
            continue
        let aidx = midx.get(aname).unwrap()
        let bidx = midx.get(bname).unwrap()
        // BFS from aidx
        var pred2: Vec[i32] = Vec.new()
        var z = 0
        while z < nm:
            pred2.push(-1)
            z = z + 1
        pred2.set_i32(aidx as i64, -2)
        var found = false
        var bchanged = true
        while bchanged and (not found):
            bchanged = false
            var i = 0
            while i < ne:
                let f = e_from.get(i as i64)
                let t = e_to.get(i as i64)
                if t >= 0 and pred2.get(f as i64) != -1 and pred2.get(t as i64) == -1:
                    pred2.set_i32(t as i64, f)
                    bchanged = true
                    if t == bidx:
                        found = true
                i = i + 1
        if pred2.get(bidx as i64) == -1:
            print("  (no path)")
        else:
            var chain: Vec[str] = Vec.new()
            var c = bidx
            var g = 0
            while c >= 0 and g < 40:
                chain.push(mname.get(c as i64))
                let pc = pred2.get(c as i64)
                if pc < 0:
                    break
                c = pc
                g = g + 1
            var ps = ""
            var ci = chain.len() as i32 - 1
            while ci >= 0:
                ps = ps ++ chain.get(ci as i64)
                if ci > 0:
                    ps = ps ++ " -> "
                ci = ci - 1
            print(f"  {ps}")
        qi = qi + 1

    print("")
    print("done.")
