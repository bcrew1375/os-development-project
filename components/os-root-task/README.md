# OS Root Task

This repository-shaped monorepo component contains the initial userspace root
task. It is built as a freestanding ELF executable and consumed by the kernel
as a boot module/runtime artifact.

The root task must not import kernel-private modules. It communicates with the
kernel only through the shared ABI package.

## Memory management

`src/memory_management/` owns root-task physical-memory policy. It validates the
delegated bootstrap descriptors, wraps memory-related ABI operations, and provides
a bounded physical-range allocator with checked absolute-address alignment,
first-fit subdivision, explicit accounting, same-parent coalescing, and
generation-checked allocation handles. Allocator instances must be initialized in
their final storage because allocation handles include the allocator address.

The root-task heap is a fixed-capacity collection of independent mapped extents.
Each extent is funded through the physical-range allocator, retyped into typed
frames, converted into a memory object, mapped through the ABI, and initialized as
a checked boundary-tag allocator before publication. Growth uses the lowest
available page-aligned virtual hole in the linker-defined heap range. Empty later
extents may be reclaimed explicitly; the initial extent is retained.

Allocator metadata is released only after the corresponding kernel capability or
memory object has been deleted. If kernel cleanup fails, the userspace allocation
remains reserved rather than becoming available for unsafe reuse.

Both linker scripts define `__root_heap_start` and `__root_heap_end` without
emitting a large loadable ELF segment. The current range is 16 MiB beginning at
`0x01000000`, and the initial committed extent is one 4 KiB page.

## Validation

```sh
zig fmt --check build.zig src tests
zig build tests
zig build -Darch=x86_32
zig build -Darch=x86_64
```

The default build expects the ABI component at
`../os-abi-library/src/abi/main.zig`. An extracted checkout can override that
location without changing source code:

```sh
zig build tests -Dabi-path=/path/to/os-abi-library/src/abi/main.zig
zig build -Darch=x86_64 \
  -Dabi-path=/path/to/os-abi-library/src/abi/main.zig
```

The kernel can consume the resulting artifact with:

```sh
zig build -Darch=x86_64 -Droot-task=/path/to/root_process.elf
```

The component retains its own build, tests, linker scripts, documentation, and
license so it can be extracted into an independent repository without
restructuring its source tree.