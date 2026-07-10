// Insert explicit `move` at method arguments selected by live compiler diagnostics.
// Sema owns the ownership decision and exact source span; this tool only validates
// token boundaries and applies source edits. Dry-run is the default.
//
//   with run tools/migrate_method_arg_moves.w <entry.w>
//   with run tools/migrate_method_arg_moves.w --apply <entry.w>

use std.process
use AnalysisTypes
use compiler.Compilation
use Lexer
use Token

extern fn with_fs_read_file(path: str) -> str
extern fn with_fs_write_file(path: str, data: str) -> i32

type OwnershipSite {
    path: str,
    offset: i32,
}

fn slice(text: str, start: i32, end: i32): text.slice(start as i64, end as i64)

fn source_path(path: str):
    let embedded = "<embedded-std>/"
    if path.starts_with(embedded): "lib/" ++ slice(path, embedded.len() as i32, path.len() as i32) else: path

fn collect_sites(entry: str) -> Vec[OwnershipSite]:
    let result = compiler_analyze_file(entry, "select:kind=diagnostic")
    let sites: Vec[OwnershipSite] = Vec.new()
    let message = "this parameter takes ownership of a non-Copy value"
    var unrelated = 0
    for i in 0..result.report.facts.len() as i32:
        let fact = result.report.facts.get(i as i64)
        if fact.kind != AnalysisFactKind.Diagnostic or fact.flags != AnalysisDiagnosticSeverity.Error as i32:
            continue
        if fact.name != message:
            unrelated = unrelated + 1
            print("migrate-method-arg-moves: unrelated compiler error: " ++ fact.name)
            continue
        if fact.path.len() == 0 or fact.start < 0:
            print("migrate-method-arg-moves: ownership diagnostic lacks a source span")
            exit_code(1)
        let path = source_path(fact.path)
        for si in 0..sites.len() as i32:
            let old = sites.get(si as i64)
            if old.path == path and old.offset == fact.start:
                print(f"migrate-method-arg-moves: duplicate compiler fact {path}:{fact.start}")
                exit_code(1)
        sites.push(OwnershipSite { path, offset: fact.start })
    if unrelated != 0:
        print(f"migrate-method-arg-moves: refusing migration with {unrelated} unrelated error(s)")
        exit_code(1)
    sites

fn migrate_file(path: str, sites: &Vec[OwnershipSite], apply: bool) -> i32:
    let text = unsafe { with_fs_read_file(path) }
    if text.len() == 0:
        print("migrate-method-arg-moves: cannot read " ++ path)
        exit_code(1)
    var lexer = Lexer.init(text, 0)
    let tokens = lexer.tokenize()
    let offsets: Vec[i32] = Vec.new()
    let labels: Vec[str] = Vec.new()
    for i in 0..sites.len() as i32:
        let site = sites.get(i as i64)
        if site.path != path: continue
        var token = -1
        for ti in 0..tokens.len():
            if tokens.get_start(ti) == site.offset:
                token = ti
                break
        if token < 0:
            print(f"migrate-method-arg-moves: compiler span is not a token boundary {path}:{site.offset}")
            exit_code(1)
        let tag = tokens.get_tag(token)
        if tag == TokenKind.TK_KW_MOVE or tag == TokenKind.TK_KW_COPY:
            print(f"migrate-method-arg-moves: compiler selected existing ownership syntax {path}:{site.offset}")
            exit_code(1)
        offsets.push(site.offset)
        labels.push(slice(text, tokens.get_start(token), tokens.get_end(token)))

    var i = 1
    while i < offsets.len() as i32:
        var j = i
        while j > 0 and offsets.get((j - 1) as i64) > offsets.get(j as i64):
            let old_offset = offsets.get((j - 1) as i64)
            let old_label = labels.get((j - 1) as i64)
            offsets.set_i32((j - 1) as i64, offsets.get(j as i64))
            labels.slot((j - 1) as i64).set(labels.get(j as i64))
            offsets.set_i32(j as i64, old_offset)
            labels.slot(j as i64).set(old_label)
            j = j - 1
        i = i + 1

    for oi in 0..offsets.len() as i32:
        print(f"{path}\t{offsets.get(oi as i64)}\t{labels.get(oi as i64)}")
    if not apply or offsets.len() == 0: return offsets.len() as i32
    let chunks: Vec[str] = Vec.new()
    var cursor = 0
    for oi in 0..offsets.len() as i32:
        let offset = offsets.get(oi as i64)
        chunks.push(slice(text, cursor, offset))
        chunks.push("move ")
        cursor = offset
    chunks.push(slice(text, cursor, text.len() as i32))
    if unsafe { with_fs_write_file(path, chunks.join("")) } != 0:
        print("migrate-method-arg-moves: failed to write " ++ path)
        exit_code(1)
    offsets.len() as i32

fn main:
    let argv = args()
    if argv.len() < 2:
        print("usage: migrate_method_arg_moves [--apply] <entry.w>")
        exit_code(1)
    let apply = argv.get(1) == "--apply"
    let entry_index = if apply: 2 else: 1
    if entry_index >= argv.len() as i32:
        print("usage: migrate_method_arg_moves [--apply] <entry.w>")
        exit_code(1)
    let sites = collect_sites(argv.get(entry_index as i64))
    let files: Vec[str] = Vec.new()
    for i in 0..sites.len() as i32:
        let path = sites.get(i as i64).path
        var seen = false
        for fi in 0..files.len() as i32:
            if files.get(fi as i64) == path: seen = true
        if not seen: files.push(path)
    var total = 0
    for i in 0..files.len() as i32:
        total = total + migrate_file(files.get(i as i64), &sites, apply)
    print(f"migrate-method-arg-moves: files={files.len() as i32} sites={total} mode=" ++ if apply: "apply" else: "dry-run")
