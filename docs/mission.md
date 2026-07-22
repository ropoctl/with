With is an ergonomics-first systems language: close to the machine, native by default, exactly as safe as Rust, and built to remove the suffering.

Every unnecessary character is a compiler failure. If With can infer it, import it, fetch it, bind it, prove it, generate it, link it, migrate it, wrap it, or make it safe, the programmer should not have to spell it out.

C interop is first-class, not an escape hatch. With should understand C headers, ABIs, native libraries, linkers, package managers, and existing C code well enough to import, integrate, and migrate them without making the programmer become the build system.

With pays compiler complexity to remove ceremony without removing guardrails. Raw C stays explicit; modeled C becomes humane. The goal is native control, Rust-level safety, and C-level reach — with the suffering automated away.

The language is named for the `with` scope: a resource lives in its scope and is released when the scope ends. Memory is the first resource, not an exception. Every allocation is owned from the moment it is made, and its owner's scope releases it — the compiler proves this the same way it proves safety. Here With is stricter than Rust: Rust calls leaking safe; With calls it a defect. Leaking memory must take deliberate, visible effort — a programmer who wants a leak has to spell it out. If the creators of the language can leak by accident, the design is wrong, not the programmer.
