# OS Development Project

An early x86 microkernel project written in Zig. The repository currently boots
on x86-32 and x86-64, loads an independently built root task, enters user mode,
and exercises a small capability-shaped syscall ABI under QEMU.

The project is intentionally **not described as a complete microkernel yet**.
Its current object registries and capability checks establish useful boundaries,
but threads, scheduling, IPC, fault containment, capability derivation, object
lifetime management, and userspace physical-memory authority are still future
work.

## Design direction

The kernel is moving toward a small, policy-light trusted core inspired by seL4:

- the kernel owns protected objects, capability enforcement, address-space
  mechanisms, execution, scheduling, IPC, interrupts, and isolation;
- the root task owns process construction, physical-memory allocation policy,
  executable loading, userspace heaps, and service orchestration;
- architecture-independent policy stays separate from physical x86 mechanisms;
- the shared ABI and root task remain independently buildable components.

Start with [Current Kernel Structure and Rationale](docs/architecture/current-state.md)
for the implemented architecture and the reasons behind it. The complete
[documentation index](docs/README.md) separates current-state documentation,
development guides, testing guides, roadmaps, and background references.

## Repository at a glance

```text
build/                     Zig build orchestration
components/os-abi-library  Cross-domain ABI and shared ELF parser
components/os-root-task    Independently built initial userspace task
src/common                 Architecture-independent kernel mechanisms
src/architecture           Mock, x86-32, x86-64, and shared x86 mechanisms
tests                      Native and physical architecture tests
tools                      Coverage, QEMU, smoke-test, and trend tooling
docs                       Architecture, workflow, testing, and roadmap docs
```

## Common commands

```sh
# Native kernel, tooling, ABI, and root-task tests
zig build tests

# Build production artifacts
zig build -Darch=x86_32
zig build -Darch=x86_64

# Exercise physical architecture implementations
zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64

# Boot the production kernel and root task end to end
zig build system-smoke -Darch=x86_32
zig build system-smoke -Darch=x86_64

# Generate Zig API documentation
zig build docs
```

See the [repository layout](docs/development/repository-layout.md) and
[testing documentation](docs/README.md#testing) for the complete command set and
validation semantics.

## Current priorities

The next major milestone is to let the root task safely construct and run a
second isolated userspace process. That requires explicit execution identity,
complete address-space objects, delegated physical-memory authority, thread and
scheduler objects, fault containment, and IPC. The detailed sequence is tracked
in the [userspace process roadmap](docs/roadmaps/userspace-process-roadmap.md).