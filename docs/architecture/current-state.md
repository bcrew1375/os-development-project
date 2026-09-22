# Current Kernel Structure and Rationale

Status date: 2026-09-22

This document summarizes the kernel as it is implemented now and explains why
its current boundaries exist. It is the architectural starting point for readers
who need context before entering the source or the detailed roadmaps.

## Maturity in one sentence

> The repository is a well-structured x86 kernel bring-up environment with a real
> userspace transition and an initial capability-shaped API, but it does not yet
> provide a complete microkernel execution or resource model.

The production system can boot on x86-32 and x86-64, load a freestanding root
ELF, enter ring 3, service system calls, enforce basic capability ownership and
rights, and observe a clean root-task exit. This is a real initial userspace
process, but it is still a bootstrap special case rather than a reusable process
model. It cannot yet schedule multiple
threads, contain a user fault, transfer capabilities, back memory objects with
delegated physical frames, or provide IPC.

## System boundary

The repository contains three independently scoped deliverables:

```text
                         shared ABI
                            ^  ^
                            |  |
                 +----------+  +----------+
                 |                        |
        privileged kernel          userspace root task
        src/, tests/                components/os-root-task
```

### Privileged kernel

`src` contains mechanisms that must execute with kernel privilege:

- boot finalization and transition to userspace;
- CPU, interrupt, and MMU control;
- virtual-address-space bookkeeping;
- capability checks and protected-object registries;
- architecture-independent syscall policy;
- bounded early allocation and platform access.

The kernel does not link root-task source. It consumes the root task as an ELF
boot artifact, preserving the user/kernel protection boundary in both the source
layout and the produced binaries.

### Shared ABI and library

`components/os-abi-library` owns definitions that cross protection domains:

- boot information;
- syscall numbers, arguments, and result conventions;
- capability handles and rights;
- system-smoke protocol records;
- shared ELF parsing helpers that are safe for kernel and userspace consumers.

Keeping these definitions out of kernel-private code prevents userspace from
acquiring accidental source-level dependencies on privileged implementation
details. The component is repository-shaped so it can later be extracted and
versioned independently.

### Root task

`components/os-root-task` is the first userspace program. Today it validates its
boot information, requests address-space and memory-object capabilities, asks the
kernel to record a mapping, and exits. In the target design it becomes the first
resource manager and process manager: policy that does not require privilege
should move there rather than expand the kernel.

## Kernel source structure

```text
src/
├── kernel.zig                  Privileged entry point and fatal boundary
├── kernel_initialization.zig   Testable initialization orchestration
├── launch_root_process.zig     ELF loading and first userspace construction
├── kernel_common.zig           Common subsystem facade
├── common/                     Architecture-independent mechanisms
└── architecture/               Hardware interfaces and implementations
    ├── architecture.zig        Selected implementation and interface checks
    ├── mock/                   Native-test implementation
    └── x86/
        ├── common/             Shared x86 mechanisms
        ├── 32/                 x86-32 implementation
        └── 64/                 x86-64 implementation
```

### Why common and architecture code are separate

Capability policy, object ownership, VMA validation, and syscall decoding should
not be rewritten for every CPU architecture. Page-table formats, privilege
transitions, descriptor tables, interrupt entry, boot protocols, and port I/O
must remain architecture-specific.

`src/architecture/architecture.zig` expresses this boundary as a compile-time
interface. Production builds select x86-32 or x86-64; native tests select the
mock. Interface validation catches missing or mismatched operations without a
runtime vtable. This uses Zig's static polymorphism to keep the abstraction both
explicit and inexpensive.

Shared x86 behavior lives under `src/architecture/x86/common`, while word-size or
page-table-format differences remain under `32` and `64`. This reduces duplicate
hardware policy without pretending that the two targets are identical.

### Why initialization is split from the entry point

`kernelMain()` is the hardware-facing fatal boundary. The sequencing before user
entry lives in `kernel_initialization.initialize()`, which receives services at
compile time. This keeps control flow visible while allowing native tests to
observe initialization order and failures without booting a machine.

`launch_root_process.zig` separately owns the first address-space construction:
it creates a hardware root, loads ELF segments, writes boot information, creates
the initial user stack, and returns a prepared transition. Separating preparation
from the non-returning user-mode entry makes most of the path testable.

## Active boot and userspace path

The current production path is:

1. the boot adapter establishes the initial kernel environment;
2. `kernelMain()` invokes the common initialization orchestrator;
3. the terminal and versioned smoke protocol are initialized;
4. a new hardware address-space root is created for the root task;
5. the root-task ELF is validated and its loadable segments are mapped;
6. boot information and an initial user stack are written through the direct map;
7. boot services are finalized and interrupts are initialized;
8. the kernel switches to the root address-space root and enters ring 3;
9. the root task uses the shared syscall ABI;
10. architecture interrupt code converts registers into a common syscall request;
11. common syscall policy performs capability and object-registry operations;
12. the root task exits and the production smoke protocol records success.

This path proves a real privilege transition and cross-domain ABI. It does not yet
prove a reusable process model: the root task is still a privileged bootstrap
special case in kernel policy and cannot create a runnable child.

## Current common subsystems

### Virtual memory

The common VMM records virtual memory areas, validates ranges and overlap, and
translates portable permissions into architecture MMU operations. The mock MMU
tracks mappings per hardware root, which lets native tests exercise explicit-root
behavior rather than accepting no-op mocks.

The root bootstrap has a real hardware root. Address-space objects created by the
syscall registry currently do not. They are metadata containers, not complete
independently activatable address spaces.

### Process and memory-object registry

`src/common/process` is currently a fixed-capacity registry for address-space and
memory-object metadata. It records ownership, sizes, VMAs, and opaque handles.
The name reflects the problem domain, but there is not yet a first-class kernel
process or thread object.

Memory objects currently have a size and ownership record but no delegated frame
backing. A successful mapping syscall proves authorization and VMA bookkeeping;
it does not yet prove shared physical storage.

### Capability table

`src/common/capability` stores fixed-capacity capability slots with an owner,
object type, rights, and generation. The shared `u32` ABI uses 7 slot-index bits
and 25 generation bits, with zero reserved as invalid. Slot reuse advances the
generation, stale handles are rejected, and exhaustion is returned explicitly.
It also prevents a caller from resolving another owner's handle or using a
handle with insufficient rights. Per-process capability spaces remain future
work; ownership is still the transitional isolation boundary.

This is useful enforcement scaffolding, not a seL4-complete capability space.
There is no per-task CSpace, derivation tree, copy, mint, attenuation, transfer,
revocation, or object-lifetime coupling yet. An internal/test-only slot deletion
primitive exists solely to validate generation advancement and stale-handle
rejection; it is not yet a public lifecycle syscall.

### Syscall policy

Architecture handlers extract register state and pass a canonical request to
`src/common/syscall`. The common dispatcher performs policy and returns an
explicit result describing return values, debug writes, exit, unsupported calls,
or failures.

This keeps ABI decoding and authorization testable on the host and minimizes
policy duplicated across x86 targets. Production syscall authorization obtains
the caller process identity from the current execution context; explicit caller
injection remains available only to common-policy test doubles.

The ownership, lifetime, authorization, and initial uniprocessor concurrency
contract for the planned object types is recorded in the [kernel object model](../kernel-object-model.md).
That contract is design documentation, not evidence that the named objects are
already implemented.

## Memory-policy direction

The inactive PMM, boundary-tag heap, and global kernel-heap facade under
`src/common/memory_management` are retained experiments. They are not the target
steady-state resource policy and should not shape new kernel interfaces.

The intended model is:

```text
boot memory map
      |
      v
kernel excludes unsafe/reserved ranges
      |
      v
root task receives bounded physical-memory authority
      |
      v
userspace chooses allocation and retyping policy
      |
      v
kernel validates capabilities and installs mappings
```

### Why allocation policy belongs in userspace

A microkernel should retain the mechanism required to protect memory without
embedding a general allocation policy in the trusted core. The kernel must still
control page tables, validate ranges and permissions, prevent aliases that
violate authority, and account for kernel-object storage. The root task should
choose which eligible frames fund processes, heaps, executable images, and
services.

Before userspace is available, the kernel necessarily uses a bounded monotonic
early allocator for page tables and bootstrap state. Long-lived kernel objects
should use fixed-capacity storage initially and later move to an explicit
capability-funded model rather than an implicit global heap.

This design is not implemented completely. The ABI does not yet transfer safe
physical-range authority or provide retype operations.

## Build and component boundaries

The root `build.zig` is an orchestration layer, decomposed by build concern under
`build/`. It creates shared modules once, builds the kernel for a selected target,
invokes the root task's independent build, packages boot artifacts, and exposes
separate steps for native tests, physical tests, coverage, smoke tests, generated
documentation, and QEMU execution.

The root task may be supplied as an external ELF with `-Droot-task`. This is a
practical enforcement point: kernel integration depends on an artifact and ABI,
not on root-task internals.

## Verification structure

The test strategy has distinct layers because each answers a different question:

| Layer | Primary question |
| --- | --- |
| Native mock tests | Is architecture-independent policy correct and observable? |
| Physical QEMU tests | Do real x86 mechanisms and fault paths behave correctly? |
| Architecture coverage | Which emitted physical paths executed? |
| Production smoke tests | Can packaged production artifacts complete the lifecycle? |

Tests live outside production source. Mock interfaces remain in parity with
physical implementations, while test-only observability stays mock-owned. The
production smoke test uses a versioned serial protocol rather than matching
ordinary diagnostic prose.

See the [testing documentation](../README.md#testing) for commands and protocol
details.

## What is implemented versus planned

| Area | Current state | Intended direction |
| --- | --- | --- |
| Architectures | x86-32, x86-64, and native mock | More implementations behind the same interface |
| Userspace | One bootstrapped root task | Isolated threads and protection domains |
| Address spaces | Hardware root only for the root task | Hardware root for every address-space object |
| Memory objects | Ownership, size, rights, and VMA metadata | Delegated physical backing and lifetime |
| Capabilities | Global owner/type/rights table | Per-space derivation, transfer, and revocation |
| Scheduling | None | Cooperative switching, then timer preemption |
| Fault handling | User faults can halt progress | Attribute and contain user faults |
| IPC | None | Synchronous endpoints, then notifications |
| Memory policy | Bootstrap allocation; PMM/heap experiments inactive | Root-task allocation policy |
| Testing | Native, physical, coverage, and smoke layers | Cover threads, faults, IPC, and child processes |

## Why the repository is shaped this way

The structure follows five rules:

1. **Protection boundaries are source and artifact boundaries.** The ABI, kernel,
   and root task do not share private implementation code.
2. **Hardware differences stop at an architecture interface.** Common policy can
   be tested once and reused across targets.
3. **The privileged core owns mechanisms, not broad policy.** Process construction
   and resource allocation are intended for the root task.
4. **Incomplete semantics are named explicitly.** Registries and capabilities are
   foundations, not evidence that scheduling, IPC, or complete memory objects
   already exist.
5. **Verification is layered.** Fast host tests, physical mechanism tests, and
   production lifecycle tests complement rather than replace one another.

These choices make the present code useful for incremental bring-up while
preserving a path toward a small capability-oriented kernel instead of allowing
bootstrap conveniences to become permanent monolithic services.

## Known structural debt

- `src/kernel.zig` still contains large disabled PMM and heap experiments that
  obscure the active path;
- architecture syscall entry still assumes the root process as caller identity;
- registered address spaces and memory objects overstate their current semantics;
- object destruction and storage reclamation are undefined;
- x86 interrupt and fault policy still has duplication and limited containment;
- no locking or CPU-local ownership model exists because preemption and SMP have
  not yet been introduced.

The dated [kernel assessment](../roadmaps/kernel-assessment.md) contains the full
priority critique. The
[userspace process roadmap](../roadmaps/userspace-process-roadmap.md) turns the
next architecture milestone into phased work.

## Reading order for contributors

1. this document for the system model;
2. [Repository Layout](../development/repository-layout.md) for ownership and
   validation commands;
3. `src/kernel_initialization.zig` and `src/launch_root_process.zig` for the active
   boot path;
4. `src/architecture/architecture.zig` for the hardware abstraction contract;
5. `src/common/syscall`, `capability`, and `process` for current object policy;
6. the [kernel object model](../kernel-object-model.md) before changing object
   ownership, lifetime, authorization, or concurrency assumptions;
7. the [kernel assessment](../roadmaps/kernel-assessment.md) for limitations;
8. the [userspace process roadmap](../roadmaps/userspace-process-roadmap.md) before
   changing the object, memory-authority, execution, or IPC model.
