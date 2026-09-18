# Repository Layout

The project is a monorepo containing three independently scoped deliverables:

- `src` and `tests`: privileged kernel code, architecture implementations,
  kernel tests, and boot-image packaging.
- `components/os-abi-library`: stable user/kernel ABI definitions and shared
  helpers usable across protection domains.
- `components/os-root-task`: the initial userspace root task, built as an
  independent freestanding ELF executable.

The component directories are ordinary tracked source trees, so a clone
contains everything needed to build and test the project. Each component is
also repository-shaped: it owns its build definition, source, tests,
documentation, and license. See [Component Workflow](component-workflow.md)
for extraction and reintegration instructions.

## Project status

See the [current kernel assessment](../kernel_analysis.md) for implementation
maturity, known architectural limitations, and the priority-ordered roadmap.
The [testing roadmap](testing-roadmap.md) tracks phased work to improve test
fidelity and expand the behavior that can be verified.

## Dependency direction

```text
os-abi-library
  ^
  |
  +-- kernel
  |
  +-- os-root-task
```

The ABI library must not depend on kernel-private or root-task code. The root
task must not import kernel-private modules and communicates with the kernel
only through the ABI.

The kernel consumes the root task as an ELF runtime artifact. It does not
compile or link root-task source into the kernel. The root task remains
independently buildable even while root-level orchestration invokes its build.

## Validation

Run every component's unit tests from the repository root:

```sh
zig build tests
```

Measure line coverage of architecture-independent kernel code with the native
mock-architecture test suite:

```sh
zig build coverage
```

The coverage report includes every Zig file under `src/common`. A line is
coverable when Zig's LLVM backend emits a sanitizer-coverage program point for
that source line, and it is covered when any program point on the line executes
during the test suite. Blank lines, comments, declarations without runtime
code, and static data are not part of the denominator. Files with no emitted
runtime locations are reported as `no emitted code`.

Zig compiles declarations lazily, so entirely unreferenced functions may not be
present in the test executable and cannot be included in the compiler-derived
denominator. The command is a reporting tool and does not currently enforce a
minimum coverage percentage.

Run architecture-dependent tests against the production x86 implementations
under headless QEMU:

```sh
zig build architecture-tests -Darch=x86_64
zig build architecture-tests -Darch=x86_32
```

Unlike `zig build tests`, these tests are a freestanding test kernel rather
than Zig `test` declarations, so `builtin.is_test` does not select the mock
architecture. The runner emits versioned `QEMU-TEST` records over COM1 and
uses QEMU's `isa-debug-exit` device for an authoritative result. The host kills
tests that run longer than 60 seconds. Override this when diagnosing a slow
environment with `-Darchitecture-test-timeout=<seconds>`. Tests currently share
one booted machine and must restore any hardware state they modify; destructive
fault and context switch tests should use isolated QEMU instances when added.

The x86-32 runner always uses QEMU's direct Multiboot loader, independently of
the production `-Dbootloader` selection. This keeps architecture tests
deterministic and avoids making them depend on ISO and Limine tooling. The
x86-64 runner uses Limine because QEMU has no equivalent direct 64-bit kernel
loader for this kernel's boot protocol.

Measure architecture line coverage with:

```sh
zig build architecture-coverage -Darch=x86_32
zig build architecture-coverage -Darch=x86_64
```

This builds a separate ReleaseFast test kernel with LLVM trace-pc-guard
instrumentation. The guest sends the total instrumentation-point count and
a covered-guard bitmap over a binary `isa-debugcon` channel. A host collector
derives guarded basic blocks from the exact emitted LLVM IR. Every debug-mapped
source line containing an instruction in a block is coverable, and all such
lines become covered when that block's guard executes. The collector then
reuses `tools/coverage/report.zig` for per-file totals. Zig lazy compilation
still limits the denominator to code emitted into that test kernel.
Namespace-only files, compile-time data, unreferenced implementations, and
helpers fully eliminated or inlined by the ReleaseFast coverage kernel may
therefore appear as `no emitted code`; this is not reported as either 0% or
100% coverage. This status describes the exact test binary, not whether the
source file text contains function bodies.

Physical tests exercise supported architecture behavior through production
interfaces. Private implementation hooks are not exposed solely to manufacture
a coverage denominator.

The x86-32 coverage kernel uses QEMU's direct Multiboot loader. Its sanitizer
callback, bitmap, stack-depth state, and compiler memory primitives are linked
into low bootstrap sections so instrumentation can execute before paging is
enabled. Sanitizer guards remain in the normal writable kernel data range and
are reserved and mapped with the rest of that range. The existing `coverage`
step remains the native mock-architecture report for `src/common`.

See [Architecture Coverage](architecture-coverage.md) for pipeline ownership,
protocol validation, coverage semantics, and Zig compatibility notes.

Build the kernel and root-task artifacts for either architecture:

```sh
zig build -Darch=x86_64
zig build -Darch=x86_32
```

Components can also be validated in isolation:

```sh
cd components/os-abi-library
zig build tests

cd ../os-root-task
zig build tests
zig build -Darch=x86_64
zig build -Darch=x86_32
```

The kernel can consume an explicitly supplied root-task artifact:

```sh
zig build -Darch=x86_64 \
  -Droot-task=/path/to/root_process.elf
```

## Ownership boundaries

- ABI definitions and cross-domain helpers belong in
  `components/os-abi-library`.
- Root-task policy and userspace mechanisms belong in
  `components/os-root-task`.
- Kernel mechanisms, architecture implementations, and privileged subsystems
  belong in `src`.
- Cross-boundary interaction uses the ABI or built artifacts, never relative
  source imports into another component's private implementation.