# Current Kernel Structure and Rationale

Status date: 2026-09-25

This document summarizes the kernel as it is implemented now and explains why
its current boundaries exist. It is the architectural starting point for readers
who need context before entering the source or the detailed roadmaps.

## Maturity in one sentence

> The repository is a well-structured x86 kernel bring-up environment with a real
> userspace transition, cooperative scheduling, root-task child construction, and
> an initial capability-shaped API, but it does not yet provide IPC or a complete
> microkernel service model.

The production system can boot on x86-32 and x86-64, load a freestanding root
ELF, enter ring 3, service system calls, enforce capability-space-local rights,
contain user faults, construct isolated child processes from packaged ELF
artifacts, and observe clean child/root exits. The root and child threads are
enrolled through the normal cooperative scheduler. The root task remains
bootstrap-created, while IPC and useful multi-service orchestration remain future
work.

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
- bounded cooperative thread scheduling;
- bounded early allocation and platform access.

The kernel does not link root-task source. It consumes the root task as an ELF
boot artifact, preserving the user/kernel protection boundary in both the source
layout and the produced binaries.

### Shared ABI and library

`components/os-abi-library` owns definitions that cross protection domains:

- boot information;
- syscall numbers, arguments, and result conventions;
- capability handles and rights;
- fixed-layout thread configuration inputs;
- system-smoke protocol records;
- shared ELF parsing helpers that are safe for kernel and userspace consumers.

Keeping these definitions out of kernel-private code prevents userspace from
acquiring accidental source-level dependencies on privileged implementation
details. The component is repository-shaped so it can later be extracted and
versioned independently.

### Root task

`components/os-root-task` is the first userspace program. It validates its boot
information, owns a bounded allocator for delegated physical ranges, and builds a
general-purpose userspace heap from capability-backed mapped extents. Heap growth,
suballocation, accounting, rollback, and optional empty-extent reclamation are
root-task policy. Its `process_management` subsystem exposes typed wrappers for
thread and capability-space creation, configuration, lifecycle control, authority
attenuation, delegation, deletion, and destruction. Its `ChildProcess` policy
record transactionally loads native ELF segments and a startup stack from a boot
module, owns every created resource, and supports retryable destruction. The
[root-created userspace process](userspace-processes.md) document describes the
implemented construction and execution boundary in detail.

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
8. the kernel initializes the scheduler and its reserved idle continuation, enrolls
   the real root thread, and selects it from the ready queue;
9. context activation switches the root address-space root, installs its
   privilege-transition stack, and enters ring 3;
10. the root task uses the shared syscall ABI, including cooperative `yield`;
11. architecture interrupt code converts registers into a common syscall request;
12. common syscall policy performs capability and object-registry operations;
13. the root task constructs and verifies its initial userspace heap extent;
14. the root task loads and starts a clean child ELF, alternates with it through
    cooperative yield, observes its contained exit, and destroys its resources;
15. the root task repeats construction with a child configured to execute `ud2`,
    observes contained fault attribution, resumes, and destroys the child;
16. the root task exits and the production smoke protocol records success.

This path proves reusable userspace process construction without introducing a
kernel process bundle. The root task remains a privileged bootstrap policy process,
but children use ordinary public capabilities, address spaces, memory objects,
threads, and scheduler transitions.

## Current common subsystems

### Virtual memory

The common VMM records virtual memory areas, validates ranges and overlap, and
translates portable permissions into architecture MMU operations. The mock MMU
tracks mappings per hardware root, which lets native tests exercise explicit-root
behavior rather than accepting no-op mocks.

Anonymous `map_memory` requests reserve VMA metadata only. A fault in an unbacked
VMA returns `MissingPhysicalBacking`; the kernel does not allocate a frame. Typed
memory objects map immutable physical backing transactionally, and object-backed
fault repair may reinstall a missing PTE for that same frame. Bootstrap-contiguous
mapping remains only for the bounded pre-userspace construction of root ELF
segments, the initial stack, and boot information.

### Process, thread, and memory-object registries

`src/common/process` contains fixed-capacity registries for address spaces,
architecture-neutral threads, and immutable frame-backed memory objects.
Address-space objects own hardware roots and bounded VMA metadata. Memory objects
retain physical start, size, authority identity, and mapping count.

Thread objects use generation-checked handles and record ownership, address-space
and capability-space association, initial entry metadata, lifecycle state, exit
status, attributed user faults, and one owned architecture-context handle. Common
policy validates legal transitions among `new`, `ready`, `running`, `blocked`,
`faulted`, and `exited`. Configuration transactionally allocates the architecture
context, destruction releases it, and an address space cannot be destroyed while
a thread references it.

The architecture context implementations use generation-checked pools of 32
contexts. Every context owns one page-aligned 16 KiB kernel stack. Initial
userspace state reuses the interrupt-return frame layout, while kernel-to-kernel
switches preserve the ABI callee-saved registers and saved stack pointer. Context
activation and switching install the target CR3 and TSS `esp0`/`rsp0`. The root
task now enters userspace through this context path on both x86 targets.

`src/common/process/scheduler` owns a fixed-capacity FIFO ready queue, current-thread
selection, thread state transitions, and current execution identity. A separately
reserved 16 KiB kernel continuation provides idle execution without consuming any
of the 32 userspace context slots. Idle waits interruptibly, and userspace syscall
number 2 performs cooperative `yield`; a sole runnable thread yields to itself
without a physical switch. Ready threads may be removed transactionally for
suspension or termination, and blocked threads may be resumed. Timer preemption
remains disabled.

There is no first-class kernel process object; process grouping remains userspace
policy. The root task's bounded `ChildProcess` record groups the public object
capabilities and physical allocations required for one child and owns transactional
construction/destruction.

## Bounded privileged allocation

The production kernel exposes no general-purpose PMM or heap. Retained allocation
mechanisms are bounded:

- early reservation metadata holds at most 128 ranges and returns
  `OutOfReservations` when full;
- runtime page-table storage is one 512-frame pool, with at most 64 frames owned by
  one address space;
- address-space, VMA, thread, memory-object, capability, and physical-authority
  registries use fixed-capacity arrays with explicit exhaustion;
- architecture thread contexts use 32 fixed slots with one 16 KiB kernel stack
  per slot;
- the scheduler ready queue holds at most 32 thread handles, and idle owns one
  separately reserved page-aligned 16 KiB stack;
- root ELF segments, the bounded 64 KiB initial stack, and the one-page
  boot-information blob are the only bootstrap-contiguous VMM allocations before
  userspace entry.
- child ELF segments and stacks are funded from delegated userspace physical
  authority and mapped through ordinary frame-backed memory objects.

The early allocator remains a monotonic bootstrap reservation mechanism, not a
runtime physical-memory policy service. Delegable RAM excludes every retained
reservation before authority reaches userspace.

### Capability spaces

`src/common/capability` stores up to 16 generation-checked capability-space kernel
objects, each with 128 fixed-capacity slots. The shared local capability handle uses
7 slot-index bits and 24 usable generation bits below the structured-error bit;
zero remains invalid. Slot and capability-space reuse advance generations, stale
handles are rejected, and exhaustion is explicit.

Production authorization selects the current thread's capability space, so a local
handle from one space does not resolve in another. Slots record object identity,
rights, and an optional cross-space parent reference. Userspace may install an
attenuated capability into a managed target space and later delete that target-local
slot. Physical-memory revocation follows derivation references across spaces.
Thread and capability-space objects are first-class capability targets with explicit
configure, start, suspend, resume, terminate, and manage authority.

This is still not a complete seL4 CSpace model: there are no addressable multi-level
CSpace trees, badges, endpoint transfer, or general revocation semantics for every
object type. The implemented bounded model is sufficient for U4.5 construction and
least-authority delegation.

### Syscall policy

Architecture handlers extract register state and pass a canonical request to
`src/common/syscall`. The common dispatcher performs policy and returns an
explicit result describing return values, debug writes, exit, unsupported calls,
cooperative yield, or failures.

This keeps ABI decoding and authorization testable on the host and minimizes policy
duplicated across x86 targets. Production syscall authorization obtains the caller
capability-space identity from the current execution context; explicit identity
injection remains available only to common-policy test doubles. Thread configuration
copies a fixed 32-byte ABI record through checked user-memory access before resolving
the referenced thread, address-space, and capability-space capabilities.

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

The implemented bootstrap ABI delegates validated normal-RAM ranges together with
capabilities. The root task tracks those ranges in sorted bounded free extents and
active allocation slots, performs checked first-fit allocation against absolute
physical addresses, and supplies the selected parent capability and relative
offset to the kernel retype mechanism. Kernel-global anonymous allocation paths
remain for legacy VMAs until U3.7; they are not used by frame-backed memory objects.

## Build and component boundaries

The root `build.zig` is an orchestration layer, decomposed by build concern under
`build/`. It creates shared modules once, builds the kernel for a selected target,
invokes the root task's independent build, packages root and child ELF boot
artifacts, and exposes
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
| Userspace | Bootstrapped root plus sequentially constructed isolated child processes | IPC-connected services and broader process policy |
| Address spaces | Every registered object owns a hardware root and bounded VMA registry | Thread-driven activation and broader lifecycle integration |
| Memory objects | Immutable delegated physical backing and transactional explicit-root mapping | Broader object attributes and sharing policy |
| Capabilities | Bounded generation-checked spaces, local handles, rights attenuation, cross-space install/delete, physical derivation tracking | Endpoint transfer and broader object revocation semantics |
| Scheduling | Bounded FIFO cooperative scheduler, reserved idle continuation, root/child yielding, and contained exit/fault handoff | Timer preemption and blocking IPC |
| Fault handling | User faults are attributed and contained | Process-manager consumption and richer reporting |
| IPC | None | Synchronous endpoints, then notifications |
| Memory policy | Bounded root-task physical-range allocator and capability-backed multi-extent userspace heap; no kernel PMM or heap | Capability-funded userspace services and broader reclamation policy |
| Testing | Native, physical, coverage, and protocol-v3 root/child smoke layers | Cover IPC and useful service processes |

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

- the root task owns a normal generation-checked thread and architecture context,
  and is scheduler-selected, but remains bootstrap-created rather than userspace-constructed;
- lower-level page-table reclamation is bounded by address-space destruction rather
  than performed eagerly for every empty table;
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
