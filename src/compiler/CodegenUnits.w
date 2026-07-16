// Codegen units (#650): split the whole-program LLVM module into K units so
// optimization and object emission can run per-unit (serially for now; the
// unit loop is shaped so a later milestone can fan it out across threads).
//
// Mechanism (the LLVM SplitModule shape, done over a bitcode round-trip
// because LLVM modules cannot leave their context):
//   1. The generated module is written to bitcode once.
//   2. Defined functions are enumerated in module order and greedily packed
//      into K size-balanced bins (basic-block count as the size proxy). The
//      partition is computed once, deterministically — bitcode reparses
//      preserve function order, so units match across parses by index.
//   3. Internal/private functions are externalized under a reserved
//      "__wcu$" name prefix (identically in every parse) so cross-unit
//      calls resolve at link time without colliding with runtime symbols.
//   4. Unit k keeps only its own function bodies; every other definition
//      becomes a declaration. Non-private global definitions live in unit 0
//      only; private globals stay everywhere (GlobalDCE strips the unused
//      copies); appending-linkage globals (llvm.global_ctors, llvm.used)
//      live in unit 0 only.
//   5. Each unit gets its own context, target machine, -O pipeline, and
//      object file: <obj>.u<k>.o for k >= 1, with unit 0 written to the
//      canonical object path.
//
// Determinism: the partition, renames, and per-unit pipelines are all
// order-driven with no map iteration, so stage2 == stage3 holds per unit.

use compiler.LlvmBridge.*
use compiler.Runtime

extern fn with_fs_remove_file(path: str) -> i32
@[effect(fn_ptr: escape_value, ctx: escape_value)]
extern fn with_thread_spawn(fn_ptr: *mut u8, ctx: *mut u8) -> i64
extern fn with_thread_join(handle: i64) -> i32

pub type CodegenUnitPlan {
    unit_count: i32,
    // Parallel vectors over defined-function index (definition order).
    fn_units: Vec[i32],
    fn_renames: Vec[str],
}

pub fn codegen_units_env_count() -> i32:
    let raw = runtime_getenv("WITH_CODEGEN_UNITS")
    if raw.len() == 0:
        return 1
    let n = parse(raw)
    if n < 1: 1 else: if n > 64: 64 else: n

// Enumerate defined functions in module order and pack them into K bins,
// balancing on basic-block count. Greedy least-loaded-bin assignment over a
// fixed iteration order is deterministic (ties resolve to the lowest index).
pub fn codegen_units_plan(base_module: i64, unit_count: i32) -> CodegenUnitPlan:
    let fn_units: Vec[i32] = Vec.new()
    let fn_renames: Vec[str] = Vec.new()
    let bin_loads: Vec[i64] = Vec.new()
    var bi = 0
    while bi < unit_count:
        bin_loads.push(0)
        bi = bi + 1
    var f = wl_get_first_function(base_module)
    var def_index = 0
    while f != 0:
        if wl_fn_is_declaration(f) == 0:
            var best = 0
            var best_load = bin_loads.get(0)
            var k = 1
            while k < unit_count:
                if bin_loads.get(k as i64) < best_load:
                    best = k
                    best_load = bin_loads.get(k as i64)
                k = k + 1
            fn_units.push(best)
            let best_idx = best as i64
            with bin_loads.slot(best_idx) as mut load_slot:
                load_slot.set(best_load + wl_fn_block_count(f) as i64 + 1)
            // Internalized functions must survive across objects: rename under
            // a reserved prefix so promotion to external cannot collide with
            // runtime-archive symbols. External functions keep their names.
            let linkage = wl_get_linkage(f)
            if linkage == wl_internal_linkage() or linkage == wl_private_linkage():
                fn_renames.push(f"__wcu${def_index}$" ++ wl_get_value_name(f))
            else:
                fn_renames.push("")
            def_index = def_index + 1
        f = wl_get_next_function(f)
    CodegenUnitPlan { unit_count, fn_units, fn_renames }

// Apply the plan to one parsed copy of the module, keeping only unit k's
// bodies. Function identity is positional: reparsed bitcode preserves
// definition order.
fn codegen_units_strip(unit_module: i64, plan: &CodegenUnitPlan, k: i32):
    var f = wl_get_first_function(unit_module)
    var def_index = 0
    while f != 0:
        if wl_fn_is_declaration(f) == 0:
            let rename = plan.fn_renames.get(def_index as i64)
            if rename.len() > 0:
                wl_set_value_name(f, rename)
                wl_set_linkage(f, wl_external_linkage())
            if plan.fn_units.get(def_index as i64) != k:
                wl_delete_function_body(f)
            def_index = def_index + 1
        f = wl_get_next_function(f)
    if k != 0:
        // Non-private global definitions and appending-linkage arrays
        // (llvm.global_ctors, llvm.used) are owned by unit 0.
        var g = wl_get_first_global(unit_module)
        while g != 0:
            let next = wl_get_next_global(g)
            if wl_global_has_initializer(g) != 0:
                let linkage = wl_get_linkage(g)
                if linkage == wl_appending_linkage():
                    wl_delete_global(g)
                else if linkage != wl_private_linkage():
                    if linkage == wl_internal_linkage():
                        wl_set_linkage(g, wl_external_linkage())
                    wl_clear_initializer(g)
            g = next
        return
    // Unit 0 keeps definitions, but internalized globals referenced from other
    // units must be externally visible there too.
    var g0 = wl_get_first_global(unit_module)
    while g0 != 0:
        if wl_global_has_initializer(g0) != 0 and wl_get_linkage(g0) == wl_internal_linkage():
            wl_set_linkage(g0, wl_external_linkage())
        g0 = wl_get_next_global(g0)

// Unit object path: unit 0 owns the canonical object path.
pub fn codegen_unit_object_path(obj_path: str, k: i32) -> str:
    if k == 0: obj_path else: f"{obj_path}.u{k}.o"

// One unit end-to-end: fresh context, reparse the shared bitcode, strip to
// this unit's bodies, optimize, emit. Every touched resource is thread-local
// (per-thread LLVMContext; the plan is read-only), so this runs identically
// inline or on a worker thread.
fn codegen_unit_emit_one(bc_path: str, obj_path: str, opt_level: i32, plan: &CodegenUnitPlan, k: i32, do_profile: bool) -> i32:
    let t_unit = runtime_clock_nanos()
    let ctx = wl_context_create()
    let unit_module = wl_parse_bitcode_in_context(ctx, bc_path)
    if unit_module == 0:
        runtime_eprint(f"error: codegen-units bitcode parse failed for unit {k}")
        wl_context_dispose(ctx)
        return 1
    codegen_units_strip(unit_module, plan, k)
    let tm = wl_init_target_machine(unit_module, opt_level)
    if tm == 0:
        runtime_eprint(f"error: codegen-units target machine init failed for unit {k}")
        wl_module_dispose(unit_module)
        wl_context_dispose(ctx)
        return 1
    if opt_level > 0:
        wl_optimize(unit_module, tm, opt_level)
    let unit_obj = codegen_unit_object_path(obj_path, k)
    if wl_emit_object(tm, unit_module, unit_obj) != 0:
        runtime_eprint(f"error: codegen-units emit failed for unit {k}: {unit_obj}")
        wl_dispose_target_machine(tm)
        wl_module_dispose(unit_module)
        wl_context_dispose(ctx)
        return 1
    wl_dispose_target_machine(tm)
    wl_module_dispose(unit_module)
    wl_context_dispose(ctx)
    if do_profile:
        let unit_ns = runtime_clock_nanos() - t_unit
        runtime_eprint(f"[profile] llvm.unit{k}  {unit_ns / 1000000}.{(unit_ns % 1000000) / 1000} ms")
    0

type CodegenUnitJob {
    bc_path: str,
    obj_path: str,
    opt_level: i32,
    unit_index: i32,
    do_profile: i32,
    plan: CodegenUnitPlan,
    rc: i32,
}

// Thread entry, following the comptime-parallel precedent
// (ComptimeEval.comptime_workspace_thread_entry): the worker touches only
// its job slot, bridge externs, and a read-only plan copy — no compiler
// globals — which is what keeps raw runtime threading sound here.
unsafe fn codegen_unit_thread_entry(arg: *mut u8) -> i32:
    let job = arg as *mut CodegenUnitJob
    (*job).rc = codegen_unit_emit_one((*job).bc_path, (*job).obj_path, (*job).opt_level, &(*job).plan, (*job).unit_index, (*job).do_profile != 0)
    0

// Write bitcode once, then run every unit's parse/strip/optimize/emit on its
// own thread (per-thread LLVMContext is the LLVM threading contract). A
// failed spawn degrades that unit to inline execution rather than failing
// the build. Returns 0 on success; emits loudly on failure.
pub fn codegen_units_emit(base_module: i64, obj_path: str, opt_level: i32, unit_count: i32, do_profile: bool) -> i32:
    let plan = codegen_units_plan(base_module, unit_count)
    let bc_path = obj_path ++ ".units.bc"
    if wl_write_bitcode(base_module, bc_path) != 0:
        runtime_eprint("error: codegen-units bitcode write failed")
        return 1
    let jobs: Vec[CodegenUnitJob] = Vec.new()
    var ji = 0
    while ji < unit_count:
        jobs.push(CodegenUnitJob {
            bc_path,
            obj_path,
            opt_level,
            unit_index: ji,
            do_profile: if do_profile: 1 else: 0,
            plan: codegen_units_plan_copy(&plan),
            rc: 0,
        })
        ji = ji + 1
    let handles: Vec[i64] = Vec.new()
    let handle_units: Vec[i32] = Vec.new()
    var k = 0
    while k < unit_count:
        unsafe:
            let job_ptr = (jobs.ptr as *mut CodegenUnitJob) + k as u64
            let handle = with_thread_spawn(codegen_unit_thread_entry as *mut u8, job_ptr as *mut u8)
            if handle < 0:
                // Degrade to inline execution for this unit.
                (*job_ptr).rc = codegen_unit_emit_one(bc_path, obj_path, opt_level, &plan, k, do_profile)
            else:
                handles.push(handle)
                handle_units.push(k)
        k = k + 1
    var join_rc = 0
    var hi = 0
    while hi < handles.len() as i32:
        let rc = with_thread_join(handles.get(hi as i64))
        if rc != 0 and join_rc == 0:
            join_rc = rc
        hi = hi + 1
    if join_rc != 0:
        runtime_eprint(f"error: codegen-units worker thread failed with exit code {join_rc}")
        let _ = with_fs_remove_file(bc_path)
        return 1
    var unit_rc = 0
    var ri = 0
    while ri < unit_count:
        if jobs.get(ri as i64).rc != 0 and unit_rc == 0:
            unit_rc = jobs.get(ri as i64).rc
        ri = ri + 1
    let _ = with_fs_remove_file(bc_path)
    unit_rc

fn codegen_units_plan_copy(plan: &CodegenUnitPlan) -> CodegenUnitPlan:
    let fn_units: Vec[i32] = Vec.new()
    let fn_renames: Vec[str] = Vec.new()
    for i in 0..plan.fn_units.len() as i32:
        fn_units.push(plan.fn_units.get(i as i64))
    for i in 0..plan.fn_renames.len() as i32:
        fn_renames.push(plan.fn_renames.get(i as i64))
    CodegenUnitPlan { unit_count: plan.unit_count, fn_units, fn_renames }

pub fn codegen_unit_extra_objects(obj_path: str, unit_count: i32) -> Vec[str]:
    let extras: Vec[str] = Vec.new()
    var k = 1
    while k < unit_count:
        extras.push(codegen_unit_object_path(obj_path, k))
        k = k + 1
    extras
