# Root-Process Preparation

Root-process preparation turns boot module zero into a protected userspace
execution image. The operation is transactional where practical: capability and
physical-memory delegation created during preparation is rolled back if a later
stage fails. `src/launch_root_process.zig` is the public facade; the mechanics live
in `src/root_process/`, where one module owns each mechanism and
`preparation.zig` owns the single `PreparedRootProcess` transaction, so every
unpublished resource has one owner and rollback order is local to it.

```mermaid
flowchart TD
    begin[prepareRootProcess] --> root[Create hardware address-space root]
    root --> cap[Register root address-space capability]
    cap --> resolve[Resolve manageable address-space handle]
    resolve --> activate[Select bootstrap VMM address space]
    activate --> module[Read boot module zero]
    module --> elf[Parse root-task ELF]
    elf --> segments[Map, copy, zero, and protect loadable segments]
    segments --> stack[Map initial userspace stack]
    stack --> modules[Map non-root boot modules read-only]
    modules --> bootPage[Map boot-info page]
    bootPage --> collect[Normalize memory and create untyped capabilities]
    collect --> write[Write boot info and descriptors into userspace]
    write --> frame[Write architecture-compatible initial call frame]
    frame --> result[Return PreparedRootProcess]

    root -. failure .-> rollback[Destroy created objects or capabilities]
    cap -. failure .-> rollback
    collect -. failure .-> rollback
    write -. failure .-> rollback
    rollback --> error[Return preparation error]

    classDef failure fill:#7f1d1d,color:#ffffff,stroke:#ef4444;
    class rollback,error failure;
```

## Address-space construction

The kernel creates a hardware page-table root, registers it through the normal
address-space object and capability path, resolves manage rights for the root
process, and makes the corresponding VMM object the active bootstrap target.
The process facade coordinates this flow while the address-space registry owns the
bounded slot, VMA backing, and handle counter.

## ELF loading

Boot module zero is validated against the direct-map range and parsed as a
loadable ELF image. Each loadable segment receives page-aligned userspace
mappings; file bytes are copied, remaining memory is zeroed, and final
permissions are applied from the ELF segment flags.

## Bootstrap mappings

Preparation creates two non-ELF mappings:

- a committed initial user stack ending at `0x00C00000`;
- a boot-info page at `0x00100000`.

The boot-info blob contains the shared ABI header, boot-module descriptors, and
normalized allocatable physical-memory ranges. Each delegated physical range is
paired with an untyped-memory capability owned by the root process.

## Initial call state

`PreparedRootProcess` returns:

- the registered address-space handle;
- the root address-space capability;
- the architecture page-table root;
- the ELF entry point; and
- the initial stack pointer.

The stack contains the x86-32 cdecl-compatible fake return address and boot-info
argument. x86-64 also passes the boot-info address in `rdi` during the privilege
transition.

## Implementation authority

- `src/launch_root_process.zig`
- `src/root_process/preparation.zig` (ownership transaction)
- `src/root_process/executable_loading.zig`
- `src/root_process/initial_stack.zig`
- `src/root_process/boot_info.zig`
- `src/root_process/boot_modules.zig`
- `src/root_process/user_memory.zig`
- `src/root_process/layout.zig`
- `src/common/memory_management/vmm.zig`
- `src/common/memory_management/physical_memory_bootstrap.zig`
- `src/common/memory_management/physical_memory_authority.zig`
- `src/common/process/main.zig`
- `src/common/process/address_space_registry.zig`
- `src/common/process/memory_object_registry.zig`
- `src/common/capability/main.zig`
- `components/os-abi-library/src/executable/elf.zig`
