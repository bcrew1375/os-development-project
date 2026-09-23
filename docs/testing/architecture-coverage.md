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
   instrumentation and owns the compatibility relink. Coverage executes the
   architecture manifest's `shared_machine` tests; isolated and expected-fault
   kernels are validated by `architecture-tests` but are not merged into the
   coverage bitmap.
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
   with `tools/coverage/report/main.zig`. The architecture reporter inventories
   sources from `source_manifest.zig`, so each report includes only source trees
   applicable to that coverage artifact's architecture and boot protocol.

## Coverage semantics

A line is coverable when the exact instrumented binary contains a debug-mapped
instruction in a sanitizer-guarded basic block. It is covered when that block's
guard executes. Zig compiles declarations lazily and ReleaseFast can inline or
eliminate helpers, while Debug retains more independently mapped instructions.
Source files with debug-mapped executable code but no guarded locations are shown
as `no coverable code`. Files with no emitted runtime locations are shown as
`no emitted code`; neither classification is treated as 0% or 100% covered. The
`Missing` column contains only compiler-emitted coverable lines whose guarded
blocks did not execute. It does not classify intentionally uninstrumented,
unreferenced, or optimized-away source as missing.

The x86-32 artifact boots through Multiboot, so its report excludes the inactive
x86-32 and shared Limine source trees. The x86-64 artifact boots through Limine
and includes both its architecture frontend and the shared Limine implementation.

Tests should validate supported architecture behavior. Production interfaces
must not expose private implementation hooks solely to make code appear in the
coverage denominator. Behavior that must appear in the shared coverage artifact
must be exercised by a safe `shared_machine` test. Each x86 descriptor-table
initialization test runs last in its architecture's shared sequence so the real
GDT, IDT, and common interrupt initialization code is emitted and measured
without affecting later shared tests.

## x86-32 early boot

Instrumentation executes before paging is enabled. The x86-32 coverage linker
script therefore keeps the sanitizer callback, bitmap, stack state, and required
compiler memory primitives in low bootstrap sections. The coverage-only linker
script also keeps sanitizer guards in writable low bootstrap data so guarded
functions can execute before paging is enabled. These rules belong to the
coverage test artifact, not the production Multiboot linker script.

The x86-32 coverage kernel uses ReleaseFast because the Debug artifact does not
reach the test protocol under Multiboot. The x86-64 coverage kernel uses Debug
because it boots reliably and retains substantially more source locations. Both
settings apply only to coverage artifacts; production optimization is unchanged.

## Updating Zig

When changing Zig versions:

1. Run the Python adapter tests through `zig build tests`.
2. Build both `architecture-coverage-kernel` targets.
3. Run both end-to-end architecture coverage commands.
4. Inspect generated LLVM IR before changing rewrite or parser assumptions.

The rewrite must fail explicitly when Zig no longer emits the expected single
sanitizer stack declaration. Remove the workaround when Zig can directly link a
freestanding trace-pc-guard binary without it.