//! expect-stdout: ok

// Pins the codegen-unit decisions (#681): unit COUNT scales to cores (memory
// never caps it — measured peaks are K-independent when all units optimize
// at once), and memory instead bounds emit CONCURRENCY via the window.

use compiler.CodegenUnitsPolicy

fn gib(n: i64): n * 1024 * 1024 * 1024

fn main:
    // --- unit count: size gate, then cores, clamped at 16 ---
    assert(codegen_units_count_for(1999, 16) == 1)
    assert(codegen_units_count_for(0, 8) == 1)
    assert(codegen_units_count_for(50000, 4) == 4)
    assert(codegen_units_count_for(50000, 8) == 8)
    assert(codegen_units_count_for(50000, 16) == 16)
    assert(codegen_units_count_for(50000, 18) == 16)
    assert(codegen_units_count_for(50000, 32) == 16)
    // Degenerate sysinfo: unknown cores → 1.
    assert(codegen_units_count_for(50000, 0) == 1)

    // --- emit window: budget = mem − 5 GiB frontend reserve, per-unit = IR/K ---
    // Cost chosen so estimated total IR = 8 GiB, independent of the
    // calibration constant's exact value.
    let c8 = gib(8) / codegen_units_bytes_per_stmt()

    // Single unit: always width 1.
    assert(codegen_units_emit_width_for(1, c8, gib(64)) == 1)
    // The 8 GB target host: 3 GiB budget over 512 MiB units → 6 in flight.
    assert(codegen_units_emit_width_for(16, c8, gib(8)) == 6)
    // Same host, chunkier units (K=8 → 1 GiB each) → 3 in flight.
    assert(codegen_units_emit_width_for(8, c8, gib(8)) == 3)
    // 6 GiB host: 1 GiB budget → single unit at a time.
    assert(codegen_units_emit_width_for(8, c8, gib(6)) == 1)
    // At or under the frontend reserve: never more than one.
    assert(codegen_units_emit_width_for(16, c8, gib(5)) == 1)
    assert(codegen_units_emit_width_for(16, c8, gib(2)) == 1)
    // Big host: every unit concurrent (today's behavior preserved).
    assert(codegen_units_emit_width_for(16, c8, gib(64)) == 16)
    assert(codegen_units_emit_width_for(16, c8, gib(128)) == 16)
    // Tiny module: cost rounds to nothing → no throttling.
    assert(codegen_units_emit_width_for(16, 0, gib(8)) == 16)

    // Compiler-scale canary: plan_cost measured 2026-07-18 (289004 stmts,
    // ~10.4 GiB est IR). An 8 GB host windows 4 of 16 units (~7.5 GB peak);
    // a 16 GB host keeps all 16 in flight.
    assert(codegen_units_emit_width_for(16, 289004, gib(8)) == 4)
    assert(codegen_units_emit_width_for(16, 289004, gib(16)) == 16)

    print("ok")
