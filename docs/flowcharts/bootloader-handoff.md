# Bootloader Handoff

This path begins with a packaged production image and ends when an
architecture-specific `_start` function transfers control to the architecture
bootstrap. The root-task ELF is a separate artifact and must be supplied as boot
module zero; it is never linked into the kernel.

```mermaid
flowchart TD
    build[Build kernel.elf and root_process.elf] --> arch{Selected architecture}
    arch -->|x86-64| limine64[Package native Limine image]
    arch -->|x86-32 default| limine32[Package Limine ISO using Multiboot 1]
    arch -->|x86-32 optional| multiboot32[Use QEMU direct Multiboot loader]

    limine64 --> module64[Attach root_process.elf as module zero]
    limine32 --> module32[Attach root_process.elf as module zero]
    multiboot32 --> moduleMb[Attach root_process.elf as module zero]

    module64 --> entry64[x86-64 native Limine _start]
    module32 --> capture[Enter x86-32 Multiboot _start]
    moduleMb --> capture

    entry64 --> setup64[x86-64 kernelSetup]
    capture --> state[Capture Multiboot table pointer and install bootstrap stack]
    state --> setup32[x86-32 kernelSetup]
```

## Architecture differences

### x86-64

Limine satisfies the declared HHDM, memory-map, module, and framebuffer
requests before calling `_start`. The entry adapter immediately calls the
x86-64 `kernelSetup` routine.

### x86-32

Both x86-32 launch choices use the same naked Multiboot `_start`. The default
path places the kernel in a Limine ISO whose configuration selects
`protocol: multiboot1`; the optional path asks QEMU to load the same kernel and
root-task module directly. The entry adapter disables interrupts, saves the
Multiboot information pointer from `ebx`, installs a bootstrap stack, and jumps
to x86-32 `kernelSetup`.

Both x86-32 choices converge before early allocation and paging setup.

## Failure boundary

Missing or malformed root-task module state is detected later during
[root-process preparation](root-process-preparation.md). Architecture bootstrap
failures panic or halt before `kernelMain` can continue.

## Implementation authority

- `build/configuration.zig`
- `build/artifacts.zig`
- `build/limine.zig`
- `build/run.zig`
- `src/architecture/x86/64/boot/limine/main.zig`
- `src/architecture/x86/32/boot/limine/limine.conf`
- `src/architecture/x86/32/boot/multiboot/main.zig`
