# OS Root Task

This repository-shaped monorepo component contains the initial userspace root
task. It is built as a freestanding ELF executable and consumed by the kernel
as a boot module/runtime artifact.

The root task must not import kernel-private modules. It communicates with the
kernel only through the shared ABI package.

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