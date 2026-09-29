# Current Kernel Structure and Rationale

Status date: 2026-09-29

This document summarizes the kernel as it is implemented now and explains why
its current boundaries exist. It is the architectural starting point for readers
who need context before entering the source or the detailed roadmaps.

## Maturity in one sentence

> The repository is a functioning early x86 microkernel prototype with real
> userspace process construction, cooperative scheduling, blocking IPC, capability
> transfer, managed faults, notifications, and one independently split service,
> but it is not yet preemptive, scalable, hardware-general, or production-ready.

The production system can boot on x86-32 and x86-64, load a freestanding root
ELF, enter ring 3, service system calls, enforce capability-space-local rights,
contain user faults, construct isolated child processes from packaged ELF
artifacts, and observe clean child/root exits. The root and child threads are
enrolled through the normal cooperative scheduler, complete blocking
request/reply exchanges, transfer attenuated capabilities into exact destination
slots, deliver lifecycle and fault events to a process manager, receive a timer
notification, and run an independently built restartable echo service. The root
task remains bootstrap-created, while timer preemption, modern interrupt routing,
and a general multi-service environment remain future work.

## System boundary

The repository contains four independently scoped deliverables:

```text
                              shared ABI
                         ^        ^        ^
                         |        |        |
              +----------+   +----+----+   +----------+
              |              |         |              |
     privileged kernel   userspace root task   userspace echo service
     src/, tests/         components/           components/
                         os-root-task           os-echo-service
```

### Privileged kernel

`src` contains mechanisms that must execute with kernel privilege:

- boot finalization and transition to userspace;
- CPU, interrupt, and MMU control;
- virtual-address-space bookkeeping;
- capability checks and protected-object registries;
- architecture-independent syscall policy;
- bounded cooperative thread scheduling;
- bounded buffered endpoints with scheduler-integrated blocking;
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

### Echo service

`components/os-echo-service` is the first service extracted from root-task policy.
It is an independent freestanding ELF that imports only the stable ABI, receives a
receive-only request endpoint and send-only reply endpoint, performs one fixed
three-word exchange, and exits. Production smoke destroys and restarts it against
the same endpoints, demonstrating narrow delegated authority and service
restartability without shared implementation state.

## Kernel source structure

```text
src/
├── kernel.zig                  Privileged entry point and fatal boundary
├── kernel_initialization.zig   Testable initialization orchestration
├── launch_root_process.zig     Public first-userspace preparation facade
├── root_process/               First-userspace preparation mechanics
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

Interrupt dispatch follows this boundary explicitly. One compile-time-parameterized
x86 policy owns exception routing, user-fault containment, page-fault resolution,
timer and keyboard handling, PIC acknowledgement ordering, diagnostics, syscall
result handling, and idle scheduling decisions. The x86-32 and x86-64 adapters
retain their trap-frame layouts, CR2 access, selector and register widths, syscall
argument extraction, result truncation/writeback, and assembly-facing handler
signatures. Compile-time contract checks reject adapter drift without adding a
runtime vtable.

### Why initialization is split from the entry point

`kernelMain()` is the hardware-facing fatal boundary. The sequencing before user
entry lives in `kernel_initialization.initialize()`, which receives services at
compile time. This keeps control flow visible while allowing native tests to
observe initialization order and failures without booting a machine.

`launch_root_process.zig` is the public facade over `src/root_process/`, which owns
the first address-space construction: it creates a hardware root, loads ELF
segments, writes boot information, creates the initial user stack, and returns a
prepared transition. Separating preparation from the non-returning user-mode entry
makes most of the path testable. Within the namespace, `layout.zig` and
`errors.zig` hold the shared virtual-address map and error set; `user_memory.zig`,
`executable_loading.zig`, `initial_stack.zig`, `boot_modules.zig`, and
`boot_info.zig` hold one mechanism each; and `preparation.zig` owns the single
preparation transaction, so every unpublished resource has one owner and rollback
order is local to it.

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
14. the root task exercises blocking endpoint request/reply and atomic capability
    transfer with rights attenuation;
15. clean and faulting children report lifecycle events through manager-owned
    endpoints, and the responsible resources are reclaimed;
16. the root binds the timer to a notification, blocks through the idle
    continuation, receives the interrupt count, and acknowledges the source;
17. the root loads the independent echo service, completes request/reply, destroys
    it, and repeats the cycle to prove restartability;
18. the root task exits and the production protocol-9 smoke record completes.

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

`src/common/ipc` owns 32 generation-checked endpoint objects. Each endpoint has an
eight-message FIFO plus fixed-capacity FIFO sender and receiver wait queues.
Unmatched operations block the current thread without consuming a ready-queue
slot; compatible peers complete retained syscalls through the architecture
context and wake through scheduler-owned endpoint reasons. Capability deletion,
endpoint destruction, thread exit, and user fault cancel affected waiters.

`src/common/ipc/transfer_operations.zig` adds a direct-rendezvous capability transfer
path with its own transfer sender and receiver wait queues, which never match
ordinary endpoint waiters. A send names a `grant`-authorized source capability, the
attenuated rights, and a message; a receive names an exact destination slot in the
receiving capability space. Delivery is transactional: the transfer validates the
source rights and destination availability and prepares the scheduler wake before
committing the installed capability, so a failure leaves the sender's, receiver's,
and endpoint's state unchanged. `src/common/syscall` exposes it as the
`endpoint_send_capability` and `endpoint_receive_capability` syscalls, returning the
installed slot-local handle in an added fourth result register.

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

The subsystem has one mutable slot owner. `storage.zig` contains the bounded tables,
generation and retirement state, typed slot transactions, resolution, counting,
and in-place test reset. `derivation.zig` contains cross-space parent traversal,
installation, exact-slot commit and rollback, generic deletion, and authorization
cancellation. Memory, process, and IPC capability adapters own backing-object
lifecycle until slot installation commits. `main.zig` remains the source-compatible
public facade; internal modules do not import it.

Production authorization selects the current thread's capability space, so a local
handle from one space does not resolve in another. Slots record object identity,
rights, and an optional cross-space parent reference. Userspace may install an
attenuated capability into a managed target space and later delete that target-local
slot. Physical-memory revocation follows derivation references across spaces.

Endpoint capability transfer uses a separate transactional exact-slot path. A
`grant` right is required to derive or transfer, attenuation is validated before
mutation, an occupied or retired destination is rejected explicitly, and the
installation is rolled back without advancing its generation if delivery fails.
Traversal is iterative, bounded by the fixed slot capacities, and allocation-free.
Revocation of a physical parent
counts remaining authority references, so a revoked derivation invalidates
transferred descendants without destroying authority still referenced elsewhere.
Thread and capability-space objects are first-class capability targets with explicit
configure, start, suspend, resume, terminate, and manage authority.

This is still not a complete seL4 CSpace model: there are no addressable multi-level
CSpace trees, badges, or general revocation semantics for every object type. The
implemented bounded model is sufficient for U4.5 construction, least-authority
delegation, and U5.3 atomic transfer.

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
contract is recorded in the
[kernel object model](../kernel-object-model.md). That contract covers implemented
objects and the rules that must constrain future extensions.

## Memory-policy direction

The former PMM, boundary-tag kernel heap, and global kernel-heap facade have been
removed from production common memory management. The active privileged code
contains physical-range normalization, bounded physical-authority objects, and
virtual mapping mechanisms, but no general-purpose kernel allocation policy.

The implemented model is:

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
offset to the kernel retype mechanism. Anonymous VMA requests reserve metadata
without allocating physical backing; frame-backed mappings require explicit
delegated authority.

## Build and component boundaries

The root `build.zig` is an orchestration layer, decomposed by build concern under
`build/`. It creates shared modules once, builds the kernel for a selected target,
invokes independent userspace builds, packages root, smoke-child, and echo-service
ELF boot artifacts, and exposes
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
| Userspace | Bootstrapped root, isolated managed children, timer notification, and restartable echo service | Service discovery, executable storage, and broader process policy |
| Address spaces | Every registered object owns a hardware root and bounded VMA registry | Thread-driven activation and broader lifecycle integration |
| Memory objects | Immutable delegated physical backing and transactional explicit-root mapping | Broader object attributes and sharing policy |
| Capabilities | Bounded generation-checked spaces, local handles, rights attenuation, `grant`-authorized exact-slot transfer, cross-space install/delete, reference-counted physical derivation tracking | Broader object revocation semantics and multi-level addressing |
| Scheduling | Bounded FIFO cooperative scheduler, reserved idle continuation, root/child yielding, and contained exit/fault handoff | Timer preemption and priority policy |
| Fault handling | User faults are attributed, contained, and deliverable to a process manager | Richer reporting, pager policy, and broader resumability |
| IPC | Blocking buffered endpoints, atomic capability transfer, kernel lifecycle delivery, and counted notifications | Larger payload protocols, service discovery, and broader device routing |
| Memory policy | Bounded root-task physical-range allocator and capability-backed multi-extent userspace heap; no kernel PMM or heap | Capability-funded userspace services and broader reclamation policy |
| Testing | Native, physical, coverage, and protocol-9 production smoke on x86-32 Limine, x86-32 Multiboot, and x86-64 Limine | Increase risk-driven physical coverage and service scenarios |

## Why the repository is shaped this way

The structure follows five rules:

1. **Protection boundaries are source and artifact boundaries.** The ABI, kernel,
   and root task do not share private implementation code.
2. **Hardware differences stop at an architecture interface.** Common policy can
   be tested once and reused across targets.
3. **The privileged core owns mechanisms, not broad policy.** Process construction
   and resource allocation are intended for the root task.
4. **Implemented and planned semantics are distinguished explicitly.** Existing
   scheduling, IPC, notification, and memory-object behavior is documented without
   implying preemption, scalable storage, or a complete service environment.
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
priority critique. The completed
[userspace process roadmap](../roadmaps/userspace-process-roadmap.md) records how
the current process and service model was delivered in phases.

## Reading order for contributors

1. this document for the system model;
2. [Repository Layout](../development/repository-layout.md) for ownership and
   validation commands;
3. `src/kernel_initialization.zig`, `src/launch_root_process.zig`, and its
   `src/root_process/` mechanics for the active boot path;
4. `src/architecture/architecture.zig` for the hardware abstraction contract;
5. `src/common/syscall`, `capability`, and `process` for current object policy;
6. the [kernel object model](../kernel-object-model.md) before changing object
   ownership, lifetime, authorization, or concurrency assumptions;
7. the [kernel assessment](../roadmaps/kernel-assessment.md) for limitations;
8. the [userspace process roadmap](../roadmaps/userspace-process-roadmap.md) before
   changing the object, memory-authority, execution, or IPC model.
