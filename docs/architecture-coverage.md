# Architecture Coverage

Architecture coverage measures code executed by the physical x86 implementations
inside QEMU. It is separate from the native `coverage` command, which measures
architecture-independent code through the mock architecture.

## Commands

```sh
zig build architecture-coverage -Darch=x86_32
zig build architecture-coverage -Darch=x86_64
```

Use `-Darchitecture-test-timeout=<seconds>` to override the shared QEMU timeout.
The `architecture-coverage-kernel` step installs the instrumented ELF and its
original LLVM IR without running QEMU.

## Pipeline

1. `build/architecture_test_kernel.zig` defines the shared physical-test kernel.
   `build/architecture_coverage_kernel.zig` enables LLVM trace-pc-guard
   instrumentation and owns the compatibility relink.
2. `tools/architecture_coverage/rewrite_ir.py` applies the Zig 0.15.2 sanitizer
   TLS compatibility rewrite. This is the intentionally version-sensitive part
   of the pipeline.
3. The rewritten IR is linked with a test-owned linker script from
   `tests/architecture/linker`.
4. `build/qemu_test_runner.zig` describes the run and
   `tools/architecture_test_runner.py` executes QEMU. Test records use COM1,
   while the coverage frame uses a binary `isa-debugcon` channel.
5. `tools/architecture_coverage/frame.py` validates the versioned guest frame.
6. `tools/architecture_coverage/llvm_ir.py` maps sanitizer guards to source
   locations in the original IR.
7. `collect.py` validates the ELF architecture and writes a versioned points
   stream. `points_file.zig` validates and parses that stream before aggregation
   with `tools/coverage/report.zig`.

## Coverage semantics

A line is coverable when the exact instrumented binary contains a debug-mapped
instruction in a sanitizer-guarded basic block. It is covered when that block's
guard executes. Zig compiles declarations lazily and ReleaseFast can inline or
eliminate helpers, so source files with no emitted runtime locations are shown
as `no emitted code`; they are neither 0% nor 100% covered.

Tests should validate supported architecture behavior. Production interfaces
must not expose private implementation hooks solely to make code appear in the
coverage denominator.

## x86-32 early boot

Instrumentation executes before paging is enabled. The x86-32 coverage linker
script therefore keeps the sanitizer callback, bitmap, stack state, and required
compiler memory primitives in low bootstrap sections. Sanitizer guards remain
in writable kernel data. These rules belong to the coverage test artifact, not
the production Multiboot linker script.

## Updating Zig

When changing Zig versions:

1. Run the Python adapter tests through `zig build tests`.
2. Build both `architecture-coverage-kernel` targets.
3. Run both end-to-end architecture coverage commands.
4. Inspect generated LLVM IR before changing rewrite or parser assumptions.

The rewrite must fail explicitly when Zig no longer emits the expected single
sanitizer stack declaration. Remove the workaround when Zig can directly link a
freestanding trace-pc-guard binary without it.