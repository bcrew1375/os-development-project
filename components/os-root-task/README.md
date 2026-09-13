# OS Root Task

This repository contains the initial userspace root task. It is built as a
freestanding ELF executable and consumed by the kernel as a boot module/runtime
artifact.

The root task must not import kernel-private modules. It communicates with the
kernel only through the shared ABI package.

## Validation

```sh
zig fmt --check build.zig src tests
zig build tests
zig build -Darch=x86_32
zig build -Darch=x86_64
```

The kernel can consume the resulting artifact with:

```sh
zig build -Darch=x86_64 -Droot-task=/path/to/root_process.elf
```