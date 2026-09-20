# Current Kernel Assessment

Date: 2026-09-20

This document records a high-level assessment of the current repository state.
It is the single source of truth for implementation maturity and the prioritized
technical backlog. Evergreen project conventions remain in
the [kernel code-organization reference](../reference/kernel-code-organization.md)
and [Zig code-structure reference](../reference/zig-code-structure.md).

## Executive summary

The project is a credible early kernel bring-up environment with several strong
architectural foundations:

- architecture-independent code is separated from x86-32, x86-64, and mock
  implementations;
- architecture interfaces are checked at compile time;
- the user/kernel ABI and initial root task are independently scoped
  components;
- common memory, process-registry, and capability-table logic has host tests;
- both x86 targets have deterministic physical architecture tests and production
  system-smoke tests that boot the real root task, enter ring 3, exercise the
  syscall ABI, and observe a clean root-task exit.

The kernel is not yet a functioning microkernel in the seL4 sense. It has the
shape of an initial capability system, but many exposed objects currently hold
metadata rather than complete kernel resources. It has no thread model,
scheduler, IPC endpoints, blocking operations, capability derivation or
revocation, object destruction, user-fault containment, or kernel-mediated
transfer of physical-memory authority to the root task.

The absence of an active kernel PMM and general-purpose kernel heap is no longer
an activation gap. It is the intended architectural direction: after bounded
bootstrap allocation, physical-memory allocation policy and general heap policy
belong in user space. The tracked PMM, boundary-tag heap, and global kernel-heap
facade are experimental legacy fragments, not future kernel services.

The most accurate maturity description is:

> A well-structured x86 kernel bring-up environment with an initial
> capability-shaped userspace API, but not yet a microkernel execution model.

## Assessment basis

This assessment is based on inspection of the current tracked source, tests,
build configuration, x86-64 ELF artifacts, and existing serial/QEMU logs.

The production system-smoke tests for x86-32 and x86-64 demonstrate this
sequence:

1. initialize the framebuffer console;
2. prepare and launch the first user process;
3. enter ring 3 and invoke `int 0x80`;
4. validate boot information in the root task;
5. acquire address-space and memory-object capability handles;
6. accept a capability-authorized memory-object mapping request;
7. exit the root task with status zero.

That is a meaningful end-to-end milestone. The distinction between demonstrated
behavior and metadata-only behavior is important, however: the mapping request
currently creates VMA metadata but does not prove shared object backing in an
independently activatable address space.

## Current strengths

### Real userspace bootstrap

The root-task launch path is more than API scaffolding. The kernel:

- creates a separate hardware page-table root;
- clones kernel mappings;
- validates and loads a freestanding ELF image;
- maps loadable segments and applies final permissions;
- writes boot information into user memory;
- creates an initial user stack;
- switches the active address-space root;
- enters user mode through `iret`/`iretq`;
- handles system calls through a DPL 3 interrupt gate.

The principal implementation files are:

- `src/launch_root_process.zig`;
- `src/architecture/x86/32/cpu/main.zig`;
- `src/architecture/x86/64/cpu/main.zig`;
- `src/architecture/x86/32/interrupts/interrupt_descriptor_table.zig`;
- `src/architecture/x86/64/interrupts/interrupt_descriptor_table.zig`.

### Protection-domain boundaries are reflected in the repository

The monorepo contains three independently scoped deliverables:

- privileged kernel code under `src` and `tests`;
- the stable cross-domain ABI and shared ELF parser under
  `components/os-abi-library`;
- the freestanding initial userspace task under `components/os-root-task`.

The root task communicates with the kernel only through the shared ABI and is
consumed as an ELF runtime artifact rather than linked into the kernel. This is
the correct boundary for a microkernel-oriented design.

### Memory-policy boundary matches the seL4 direction

The intended steady state is deliberately different from a conventional kernel
PMM plus kernel heap:

- the kernel uses bounded, auditable storage for kernel objects and a monotonic
  bootstrap allocator only for resources that must exist before user space;
- the kernel retains privileged MMU mechanisms, mapping validation, capability
  checks, and bookkeeping needed to protect physical resources;
- the root task receives authority over safe, available physical ranges and
  implements frame allocation, higher-level memory policy, and userspace heaps;
- user-space allocators request mappings or retype delegated physical-memory
  capabilities rather than drawing from an implicit kernel-global heap;
- device, firmware, kernel-image, boot-module, page-table, and other reserved
  ranges remain unavailable unless explicitly represented by restricted
  capabilities.

This boundary is not implemented yet. `BootInfo` currently describes only boot
modules, and the ABI has no untyped/physical-range capability or retype operation.
The existing `pmm.zig`, `heap.zig`, and `kernel_heap.zig` remain in the tree as
experimental code and tests, but they should not shape new kernel interfaces.

### Architecture separation and static validation

`src/architecture/architecture.zig` selects x86-32, x86-64, or mock
implementations and validates the required component interfaces at compile
time. This provides low-overhead static polymorphism for boot, CPU, interrupt,
MMU, early allocator, and platform services.

The source layout also distinguishes shared x86 mechanisms from word-size
specific implementations, although some policy remains duplicated between the
x86-32 and x86-64 interrupt handlers.

### Host-testable common code

Tests are kept outside source files and cover useful behavior in:

- VMA range validation and overlap detection;
- demand-fault resolution and permission checks;
- process and memory-object registries;
- capability ownership, object type, and rights checks;
- ABI layouts and basic ELF rejection.

The mock MMU records table and page mappings per address-space root, tracks page
permissions, and supports physical-address lookup. This makes common VMM tests
substantially more credible than a no-op mock would.

### Build and component workflow

The build supports both x86 targets, independently builds the root task,
accepts an externally supplied root-task artifact, runs component tests, emits
API documentation, and launches QEMU. CI checks formatting, runs native tests,
executes physical architecture tests, builds both targets, and runs production
system-smoke tests with Zig 0.15.2.

## Prioritized actionable critique

Priorities describe implementation order, not just severity. Priority 0 closes
unsafe protection-boundary behavior. Priorities 1 and 2 establish the minimum
kernel object and execution models. Later priorities improve memory correctness,
IPC, verification, hardware support, and maintainability.

### Priority 0: protection-boundary safety

#### P0.1 Replace direct userspace pointer dereferences

**Problem:** The `debug_write` syscall converts a userspace integer directly
into a kernel pointer and passes the resulting slice to the platform writer.
There is no range, overflow, mapping, permission, or maximum-length validation.

**Why it matters:** A malformed pointer can fault in kernel context. Depending
on active mappings, unchecked pointers may also expose kernel memory.

**Actions:**

1. Define a common `UserAddress` or `UserSlice` representation that cannot be
   confused with a kernel pointer.
2. Add a checked range helper that rejects zero-wrap and addition overflow.
3. Reject ranges that reach or cross `arch.mmu.getKernelVirtualAddressStart()`.
4. Add an MMU/VMM query that validates every page in a range as present,
   user-accessible, and readable or writable as required.
5. Implement bounded `copyFromUser()` and `copyToUser()` helpers.
6. Define how a user-copy page fault becomes a recoverable syscall error.
7. Set a maximum `debug_write` length and copy through a fixed kernel buffer.
8. Replace both x86 handlers' direct `@ptrFromInt` use with the common helper.
9. Add tests for valid, unmapped, kernel-space, cross-page, oversized, and
   overflowing ranges.

**Done when:** No syscall handler directly dereferences a userspace-provided
address, invalid user buffers return an ABI error, and hostile pointer tests do
not panic the host-test kernel or QEMU guest.

#### P0.2 Contain user-originated faults and invalid syscalls

**Problem:** Process exit, unknown syscalls, user general-protection faults, and
unresolved user page faults can halt or panic the whole system.

**Why it matters:** A protection domain is not isolated if ordinary user failure
can stop the kernel.

**Actions:**

1. Define a small `UserFault` record containing fault type, address, instruction
   pointer, architecture error data, and access type.
2. Split kernel-originated and user-originated exception paths at common
   dispatch.
3. Return a defined `UnsupportedSyscall` result for unknown syscall numbers.
4. Introduce a temporary `faulted`/`exited` execution state before a full
   scheduler exists.
5. Route the exit syscall to the current execution context instead of directly
   calling `unrecoverableHalt()`.
6. Route user page, protection, invalid-opcode, and general-protection faults to
   the same containment path.
7. Keep panic/halt behavior only for kernel-mode exceptions and broken kernel
   invariants.
8. Add tests proving malformed user requests do not enter the kernel panic path.

**Done when:** Every user-originated exception and invalid syscall has a defined
non-panic result, while kernel-originated fatal exceptions still stop with useful
diagnostics.

#### P0.3 Common system-call dispatcher — substantially complete

**Verified status:** `src/common/syscall/main.zig` now owns architecture-neutral
syscall decoding, capability resolution, process operation selection, rights
derivation, and deterministic ABI result mapping. Both x86 adapters marshal trap
registers into the common request, and native plus physical tests exercise the
path.

**Remaining work:** Architecture handlers still own unsafe debug-pointer access,
caller identity is still hard-coded, and exit/unsupported-syscall side effects
still halt the system. Those concerns remain tracked by **P0.1**, **P0.2**, and
**P0.4** rather than by this item.

**Done when:** The remaining architecture adapters contain only trap-frame
marshalling and explicitly delegated architecture side effects. The common
policy portion of this item is complete.

#### P0.4 Make caller identity explicit

**Problem:** Every syscall is authorized as `ROOT_PROCESS_HANDLE`, regardless of
the actual caller.

**Why it matters:** Ownership checks cannot protect multiple processes if the
kernel supplies a constant identity.

**Actions:**

1. Introduce a minimal execution-context record with process identity and
   address-space identity.
2. Register the bootstrapped root task as that execution context.
3. Store the current context in one clearly owned uniprocessor location.
4. Add a `currentProcessHandle()` accessor used only at the syscall boundary.
5. Pass the retrieved handle to common syscall dispatch.
6. Add tests using at least two synthetic caller identities.
7. Document that CPU-local storage replaces the global accessor before SMP.

**Done when:** No syscall path references `ROOT_PROCESS_HANDLE` directly and
capability ownership tests exercise different current callers.

### Priority 1: complete the minimum kernel object model

#### P1.1 Write the object-model design contract

**Problem:** Address spaces, memory objects, and capabilities were added before
their complete ownership and lifetime relationships were defined. Threads and
endpoints do not yet exist.

**Why it matters:** Implementing more object types without a stable contract can
lock prototype ownership assumptions into public ABI and internal APIs.

**Actions:**

1. Add `docs/kernel-object-model.md`.
2. Define the responsibilities of `Thread`, `AddressSpace`, `MemoryObject`,
   `CapabilitySpace`, `Endpoint`, and `Notification`.
3. Define which objects own physical frames and architecture resources.
4. Define object reference, destruction, and reclamation rules.
5. Define whether process is a first-class object or a grouping of a capability
   space, address space, and threads.
6. Define capability copy, mint, rights attenuation, derivation, and revocation.
7. Define lock ownership and ordering for future preemption/SMP.
8. Record which policies belong in the root task rather than the kernel.

**Done when:** New object implementations can cite one reviewed document for
ownership, lifetime, authorization, and concurrency semantics.

#### P1.2 Attach hardware roots to address-space objects

**Problem:** A registered address-space slot contains VMA metadata but no
`arch.AddressSpaceRoot`. The actual root used by the initial task is created and
managed separately by the bootstrap loader.

**Why it matters:** A created address-space capability does not identify an
address space that can be activated, populated, assigned to a thread, or
destroyed.

**Actions:**

1. Add `arch.AddressSpaceRoot` to the internal address-space object.
2. Make address-space creation allocate the root and initialize VMA storage as
   one fallible operation.
3. Add rollback if root allocation or object-slot allocation fails.
4. Add a registration path for the root task's bootstrapped address space.
5. Remove the independent `rootAddressSpace`/root-handle split from kernel boot.
6. Make map, protect, query, and unmap operations accept an explicit registered
   address-space object/root.
7. Add address-space destruction hooks, even if physical reclamation is staged.
8. Extend the mock architecture tests to verify mappings are isolated by root.

**Done when:** Every address-space handle has exactly one hardware root, the root
task uses a registered object, and mappings target that object's root.

#### P1.3 Back memory objects with user-supplied physical authority

**Problem:** A memory object records only owner and size. VMA fault resolution
ignores its handle and offset and allocates unrelated anonymous frames through a
kernel-internal allocator path.

**Why it matters:** Mapping the same object twice does not provide shared memory,
and implicit kernel allocation conflicts with the intended seL4-style model in
which user space controls physical-memory allocation policy.

**Actions:**

1. Define a capability type representing an aligned physical range or untyped
   memory authority delegated to the root task.
2. Define a retype/create operation that consumes or subdivides that authority to
   create frame-backed memory objects without overlap.
3. Store immutable physical backing identity, size, and derivation metadata in
   each created memory object.
4. Require explicit user-supplied backing authority; do not allocate frames from
   a kernel-global PMM on mapping or fault.
5. Map the same backing pages for every mapping of the same object and offset.
6. Validate alignment, bounds, rights, object type, and cache/device attributes
   before installing mappings.
7. Make object creation and mapping transactional, including rollback when MMU
   setup fails.
8. Track capability derivation, mappings, and references needed for safe revoke
   and destruction.
9. Add tests that reject overlapping retypes and verify that one object mapped
   into two address spaces resolves to the same physical frames.
10. Extend the root-task demonstration to allocate one page from delegated
    physical authority, create a memory object, map it, and read/write it.

**Done when:** Memory-object identity is tied to explicitly delegated physical
memory, shared mapping behavior is verified, and no runtime memory-object path
implicitly calls a kernel PMM.

#### P1.4 Evolve protected handles into capability spaces

**Problem:** The current global capability table has single-owner slots,
monotonic handles, and no copy, derivation, attenuation, revocation, destruction,
or stale-handle protection.

**Why it matters:** This cannot yet model independently held authority or safely
recycle slots in a long-running system.

**Actions:**

1. Separate kernel object identity from capability-slot identity.
2. Add one capability space per process or execution domain.
3. Replace monotonically unique handles with slot plus generation identifiers.
4. Implement capability lookup within the caller's capability space.
5. Implement copy with equal rights.
6. Implement mint/derive with rights attenuation only.
7. Track parent-child derivation relationships.
8. Implement slot deletion and stale-handle rejection.
9. Implement revocation of descendants.
10. Add object reference accounting and destroy objects only when policy permits.
11. Add tests for delegation, attenuation, stale handles, revocation, slot
    exhaustion, and cross-space isolation.

**Done when:** Authority can be safely delegated and revoked without relying on
a global owner field or never-reused handles.

### Priority 2: establish a schedulable execution model

#### P2.1 Define architecture-neutral thread state

**Problem:** The root task is launched directly and has no kernel thread object
or lifecycle state.

**Why it matters:** The kernel cannot suspend, resume, terminate, or identify
execution independently from the one bootstrap path.

**Actions:**

1. Define thread identifiers and `new`, `ready`, `running`, `blocked`, `faulted`,
   and `exited` states.
2. Associate each thread with a capability space and registered address space.
3. Define an architecture context interface for initial context creation and
   saved context storage.
4. Construct the root task as the first thread instead of directly entering it.
5. Store exit status and fault information in the thread object.
6. Add fixed-capacity thread storage and exhaustion tests.

**Done when:** The root task exists as a normal thread object before first entry
and its state can be inspected after a synthetic transition.

#### P2.2 Implement cooperative context switching

**Problem:** There is no path from user execution back to a runnable kernel
context except interrupts that ultimately resume the same task or halt.

**Why it matters:** Scheduling and contained exit require a reliable context
switch before preemption is introduced.

**Actions:**

1. Specify the exact saved general-purpose, instruction, stack, flags, segment,
   and address-space state for each x86 target.
2. Add architecture context-switch functions with identical common interfaces.
3. Create an idle kernel thread/context.
4. Add a minimal fixed-capacity FIFO ready queue.
5. Add a `yield` syscall and move the running thread back to ready state.
6. Make `exit` mark the current thread exited and switch to the next thread.
7. Keep SIMD disabled until its state is saved and restored.
8. Add host state-machine tests and QEMU tests that alternate between two
   cooperative threads.

**Done when:** Two user threads can yield repeatedly and one can exit without
halting the kernel or corrupting the other's register/address-space state.

#### P2.3 Add timer preemption after cooperative switching

**Problem:** Timer support exists only as PIT initialization and diagnostics;
there is no scheduler tick.

**Why it matters:** A general-purpose kernel cannot rely on every userspace task
to yield voluntarily.

**Actions:**

1. Define scheduler tick and time-slice accounting independent of the PIT.
2. Route timer IRQs through common interrupt dispatch.
3. Decrement the current thread's quantum without console output.
4. Request rescheduling at a safe interrupt-return boundary.
5. Save the interrupted context using the same representation as cooperative
   switching.
6. Acknowledge the interrupt controller exactly once on every path.
7. Add a QEMU test where a non-yielding task is preempted by another task.

**Done when:** A CPU-bound user thread cannot starve another ready thread and
timer-driven switches preserve state.

### Priority 3: user-space physical-memory authority and mapping correctness

#### P3.1 Define the physical-memory authority ABI

**Problem:** The boot ABI exposes boot modules but not the normalized available
physical ranges or kernel reservation boundaries needed by a user-space memory
manager. The capability ABI has no physical-range/untyped object type.

**Why it matters:** The root task cannot safely become the system memory manager
without authoritative knowledge and non-forgeable authority over allocatable RAM.
Passing raw addresses without capability control would merely move bookkeeping,
not authority, into user space.

**Actions:**

1. Define a versioned, fixed-layout descriptor for page-aligned physical ranges.
2. Distinguish allocatable RAM from kernel image, page tables, boot modules,
   framebuffer/MMIO, firmware, bad memory, and retained boot data.
3. Normalize, sort, validate, align, and subtract reservations in privileged boot
   code before delegation.
4. Represent each delegated range with a root-task capability, not only an
   informational address pair.
5. Define target-width and overflow behavior for x86-32 and x86-64.
6. Specify whether descriptors are embedded in `BootInfo`, referenced through a
   bounded user mapping, or enumerated through a capability query.
7. Add ABI layout tests and adversarial range-normalization tests.

**Done when:** The root task receives a complete, non-overlapping description of
allocatable physical memory and matching capabilities that cannot name reserved
or out-of-range memory.

#### P3.2 Implement user-space frame allocation and heap policy

**Problem:** The root task currently wraps only address-space and memory-object
syscalls. It has no allocator for delegated physical ranges and no userspace heap.
The in-kernel PMM and heap fragments encode policy in the wrong protection domain.

**Why it matters:** A seL4-style design depends on the initial user-space resource
manager deciding how physical memory is partitioned, reused, and delegated.

**Actions:**

1. Add a root-task memory-management subsystem that imports only the shared ABI.
2. Implement deterministic physical-range bookkeeping over delegated capabilities.
3. Support aligned split/subrange allocation and explicit coalescing or another
   documented reclamation strategy.
4. Build a userspace allocator on mapped memory rather than exposing a kernel
   `kmalloc`-style service.
5. Keep allocator metadata in root-task-owned memory with checked arithmetic and
   explicit exhaustion errors.
6. Add host tests for holes, alignment, split, coalescing, exhaustion, duplicate
   free, and reserved-range rejection.
7. Keep the allocator policy replaceable without changing kernel-private code.

**Done when:** The root task can allocate and reclaim physical subranges and back
its own heap without importing kernel modules or relying on a kernel-global PMM.

#### P3.3 Bound and retire legacy kernel allocation paths

**Problem:** Root-task pages, address-space roots, and page tables currently use
`arch.early_allocator`, while `vmm.zig` still contains a dormant transition to
`pmm.zig`. `kernel.zig` retains a large commented PMM/heap experiment, and common
exports still make the legacy PMM and kernel heap appear architectural.

**Why it matters:** A monotonic allocator is acceptable for bounded bootstrap
objects, but an undocumented always-growing runtime path can exhaust memory and
blur the intended ownership boundary. Dormant PMM/heap paths invite future code
to depend on the wrong model.

**Actions:**

1. Inventory every bootstrap allocation and classify its lifetime and maximum
   count before the root task starts.
2. Keep a small kernel-owned mechanism for page tables and kernel-object metadata;
   prefer fixed-capacity pools or capability-funded object creation over a
   general-purpose heap.
3. Remove `earlyAllocatorActive` and the fallback from VMM allocation to the
   experimental PMM.
4. Remove PMM and kernel-heap imports, compatibility aliases, and commented boot
   activation code from production kernel paths.
5. Move reusable allocator implementations and their tests into a user-space
   memory-manager component, or delete them if they no longer match that design.
6. Preserve only the early reservation logic required to exclude privileged boot
   resources from delegation.
7. Add accounting and exhaustion tests for every retained fixed-capacity or
   bootstrap pool.
8. Fail explicitly if bounded kernel bootstrap storage is exhausted.

**Done when:** Production kernel code has no general-purpose PMM or heap API,
bootstrap allocation is bounded and documented, and runtime physical-memory
policy is exercised in user space.

#### P3.4 Complete explicit-root unmapping and reclamation

**Problem:** VMM unmapping targets only the current hardware address space.
Architecture `unmapPage()` cannot report absent tables and does not operate on
an explicit root. Frames and empty tables are not reclaimed through a defined
policy.

**Why it matters:** Independent address spaces and object destruction require
safe, target-specific cleanup.

**Actions:**

1. Define missing-page and missing-table semantics explicitly.
2. Add `unmapPageInAddressSpace(root, address)` with a fallible return type.
3. Implement identical semantics for x86-32, x86-64, and mock MMUs.
4. Return the unmapped physical frame or provide a separate query-before-unmap
   operation.
5. Update VMM unmap to target the address-space object's root.
6. Validate the complete VMA/range before mutation.
7. Reclaim anonymous frames when mappings own them.
8. Decrement memory-object references without freeing shared frames too early.
9. Reclaim empty lower-level page tables where practical.
10. Add absent mapping, repeated unmap, cross-root, shared object, and rollback
    tests.

**Done when:** Any registered address space can be safely unmapped without being
active, and owned physical resources are reclaimed exactly once.

#### P3.5 Define effective MMU permission capabilities

**Problem:** Common permissions imply readable and executable control that not
all x86 configurations can enforce. In particular, 32-bit non-PAE x86 has no NX
bit, and ordinary present x86 pages are readable.

**Why it matters:** Callers and tests may assume stronger isolation than the
hardware supplies.

**Actions:**

1. Add an `MmuCapabilities` value to the architecture interface.
2. Report NX, user-page, global-page, and any execute-only limitations per
   implementation.
3. Define the portable permission combinations accepted by the VMM.
4. Reject unsupported security-sensitive combinations explicitly.
5. Ensure fault-policy checks match actual page-table enforcement.
6. Update process mapping validation and ABI documentation.
7. Add capability-dependent tests for mock, x86-32 compile configuration, and
   x86-64.

**Done when:** Every accepted mapping permission has documented effective
semantics on each supported architecture.

#### P3.6 Redesign the x86-64 virtual address layout

**Problem:** Some x86-64 reserved constants retain low 32-bit-style addresses,
below the declared higher-half kernel boundary. Direct-map constants also mix a
fixed legacy model with Limine's dynamic HHDM offset.

**Why it matters:** Broader user mappings or new privileged regions can create
kernel/user address collisions and contradictory range validation.

**Actions:**

1. Write a documented x86-64 virtual layout with user, guard, kernel image,
   direct map, MMIO, bootstrap pools, and reserved regions.
2. Derive all boundary constants from that layout.
3. Treat Limine's HHDM offset and validated mapped extent as the direct map.
4. Remove or rename constants that do not describe active mappings.
5. Add compile-time canonical-address and non-overlap assertions.
6. Update linker, user-range validation, bootstrap-pool bounds, and kernel
   mapping clone assumptions together.
7. Add QEMU probes for the first and last page of each active region.

**Done when:** Every x86-64 virtual region is canonical, non-overlapping, and
used consistently by the linker, MMU, VMM, and process validator.

#### P3.7 Remove the general-purpose kernel heap from the target architecture

**Problem:** `heap.zig` and `kernel_heap.zig` remain exported as kernel memory
subsystems even though the active kernel does not initialize them and the target
architecture assigns general allocation policy to user space.

**Why it matters:** Retaining an apparently supported kernel heap encourages
unbounded in-kernel object growth, complicates failure analysis, and contradicts
the intended capability-funded resource model.

**Actions:**

1. Identify any allocator code worth reusing in a root-task or user-space
   memory-manager component.
2. Move user-space allocator code and tests across the protection-domain boundary
   without introducing kernel-private imports.
3. Replace future kernel dynamic-allocation proposals with fixed-capacity storage,
   explicit object-memory donation, or another reviewed bounded mechanism.
4. Remove `kernel_heap` exports and dead heap virtual-layout constants from the
   privileged kernel.
5. Document the allowed allocation model for kernel object metadata, IPC queues,
   and scheduler structures.
6. Add tests proving retained kernel pools fail explicitly at capacity.

**Done when:** No production kernel interface exposes a general heap, user-space
owns general allocation policy, and every kernel-resident storage pool has a
bounded capacity and explicit exhaustion behavior.

### Priority 4: IPC and userspace service mechanisms

#### P4.1 Implement minimal synchronous endpoints

**Problem:** There are no IPC endpoints, messages, or blocking operations.

**Why it matters:** Without IPC, policy and services cannot move out of the
privileged kernel despite the intended microkernel architecture.

**Actions:**

1. Define endpoint and message-register ABI types.
2. Add an endpoint kernel object and capability type.
3. Add fixed-capacity sender and receiver wait queues.
4. Implement non-blocking send and receive first.
5. Add blocking send/receive using scheduler state transitions.
6. Copy a small fixed register message without user pointers.
7. Define cancellation behavior for thread exit and endpoint destruction.
8. Add ownership, rights, queue-order, cancellation, and exhaustion tests.
9. Add a two-thread QEMU ping/pong smoke test.

**Done when:** Two user threads exchange messages through an endpoint without
shared globals or kernel console mediation.

#### P4.2 Transfer capabilities through IPC

**Problem:** Even after basic IPC, userspace cannot delegate authority through
messages.

**Why it matters:** Capability transfer is central to constructing services and
resource managers outside the kernel.

**Actions:**

1. Add optional source and destination capability slots to the IPC contract.
2. Validate sender transfer rights and receiver slot availability.
3. Support rights attenuation during transfer.
4. Make message and capability delivery atomic.
5. Roll back both sides if validation or delivery fails.
6. Track derivation relationships for transferred capabilities.
7. Add tests for success, insufficient rights, occupied destination, attenuation,
   rollback, and revocation after transfer.

**Done when:** A userspace resource manager can delegate restricted authority to
another process through an endpoint.

#### P4.3 Deliver interrupts through notification objects

**Problem:** Hardware IRQs are handled only inside the kernel and cannot wake a
userspace driver.

**Why it matters:** Device drivers cannot move into userspace without a bounded
interrupt-delivery mechanism.

**Actions:**

1. Define a notification object with pending-bit/count semantics.
2. Add capabilities for binding and waiting on notifications.
3. Bind an IRQ source to one authorized notification.
4. Make the interrupt path signal without blocking or allocating.
5. Wake a waiting driver thread through the scheduler.
6. Define masking, acknowledgement, and unbind behavior.
7. Add mock interrupt-delivery tests before using physical hardware.
8. Add a timer-notification QEMU demonstration.

**Done when:** A userspace thread can block for and receive a hardware event
without the interrupt handler invoking driver policy.

### Priority 5: verification and test fidelity

The phased implementation checklist for this priority and related testing work
is maintained in the [testing roadmap](testing-roadmap.md). This
assessment remains the source for architectural motivation and priority; the
roadmap records execution status, dependencies, acceptance criteria, and
validation commands.

#### P5.1 Stabilize mock memory lifecycle — complete

**Verified status:** The mock MMU now owns configurable physical backing with
explicit initialization, reset, and deinitialization. Memory-map reads are
side-effect free, repeated fixtures release prior backing, and use before setup is
detected. This is tracked as complete by T1.3 in `testing-roadmap.md`.

#### P5.2 Make platform and interrupt mocks observable — complete

**Verified status:** Mock boot, CPU, interrupt, console, color, timer, and
acknowledgement effects are bounded, resettable, and queryable without expanding
production architecture interfaces. This is tracked as complete by T1.4.

#### P5.3 Expand ABI, ELF, and root-task tests — substantially complete

**Verified status:** ABI layout/constants, ELF fixtures and rejection paths,
root-process preparation, root-task transport, startup policy, and wrapper
argument ordering now have dedicated tests. Continue extending these tests as the
physical-memory authority ABI, capability types, and IPC contract are added.

#### P5.4 Add deterministic QEMU smoke tests — complete for the current scenario

**Verified status:** Both x86 targets have deterministic architecture tests and
production system-smoke tests with timeout handling, machine-readable protocols,
authoritative completion, and CI enforcement. The current smoke scenario proves
boot, user entry, boot-info validation, capability acquisition, metadata mapping,
and clean exit; future object-backing and scheduling milestones should extend the
same protocol rather than create an unrelated runner.

#### P5.5 Remove redundant CI work and expose explicit verification steps — complete

**Verified status:** Native tests run once outside the architecture matrix. Each
architecture then runs physical tests, builds the coverage kernel and production
artifacts, and executes the production system smoke. Repository documentation
lists the local validation commands and the aggregate `zig build tests` step
remains available.

### Priority 6: interrupt architecture and platform discovery

#### P6.1 Introduce an interrupt-controller interface

**Problem:** Interrupt acknowledgement and IRQ masking are directly coupled to
the legacy PIC.

**Why it matters:** APIC routing, MSI, and per-CPU interrupt handling cannot be
added cleanly behind the current call sites.

**Actions:**

1. Define controller operations for initialize, mask, unmask, acknowledge, and
   vector/IRQ translation.
2. Implement the interface with the current PIC backend.
3. Move PIC selection out of IDT construction.
4. Route PIT and keyboard unmasking through the controller interface.
5. Make spurious IRQ behavior explicit.
6. Add an observable mock controller with parity tests.

**Done when:** No generic interrupt or platform-time code imports the PIC module
directly.

#### P6.2 Add ACPI discovery and APIC routing

**Problem:** The kernel has no ACPI table discovery, MADT parser, Local APIC, or
I/O APIC support.

**Why it matters:** The PIC limits interrupt routing and blocks production-grade
multicore and modern hardware support.

**Actions:**

1. Obtain and validate RSDP information from the boot protocol.
2. Parse RSDT/XSDT headers with checksum and bounds validation.
3. Locate and parse MADT entries into architecture-neutral topology records.
4. Map Local APIC and I/O APIC MMIO with device-memory attributes.
5. Disable or fully mask the legacy PIC when APIC mode is selected.
6. Initialize the bootstrap processor's Local APIC.
7. Program I/O APIC redirection for timer and keyboard IRQs, including source
   overrides.
8. Add parser tests using fixed ACPI table fixtures.
9. Add a QEMU APIC-mode interrupt smoke test while preserving PIC fallback.

**Done when:** Supported QEMU machines route selected hardware interrupts through
APIC and malformed ACPI input fails explicitly.

#### P6.3 Add dedicated emergency exception stacks

**Problem:** x86-64 IDT entries use IST zero even though the TSS contains IST
fields.

**Why it matters:** Double faults, NMIs, and stack-corruption faults may be
unable to run a diagnostic handler on the damaged stack.

**Actions:**

1. Reserve fixed, guarded stacks for double fault and NMI.
2. Populate the corresponding TSS IST entries.
3. Assign nonzero IST indexes to the selected IDT gates.
4. Verify stack alignment at the Zig/C ABI boundary.
5. Ensure emergency handlers avoid allocation and unsafe locking.
6. Add a controlled QEMU double-fault test build.

**Done when:** A controlled stack-failure scenario reaches the emergency handler
on the expected dedicated stack.

#### P6.4 Define the path to SMP safely

**Problem:** VMM state, capability/object registries, diagnostics, retained
bootstrap allocators, and current execution state use unprotected global mutable
state and are implicitly uniprocessor.

**Why it matters:** Enabling additional CPUs or preemption without ownership and
locking rules would introduce races throughout the kernel.

**Actions:**

1. Document subsystem state ownership before adding application processors.
2. Introduce CPU-local current-thread and interrupt state.
3. Define lock primitives and interrupt-save semantics.
4. Establish and document a global lock order.
5. Add synchronization to capability spaces, object registries, retained
   kernel pools, and scheduler queues one subsystem at a time.
6. Keep the build explicitly single-CPU until those contracts are enforced.
7. Add application-processor startup only after synchronized scheduler state
   exists.

**Done when:** The kernel can explain and mechanically enforce who owns every
shared mutable structure before a second CPU executes kernel code.

### Priority 7: maintainability and documentation

#### P7.1 Remove dead or misleading x86-64 bootstrap code — complete

**Verified status:** The obsolete `src/architecture/x86/64/mmu/early_boot.zig`
file is absent, and current x86-64 MMU sources belong to the active Limine path or
shared architecture mechanisms. New architecture entry points should continue to
be exercised by production builds or physical tests so Zig lazy analysis cannot
hide dead implementations.

#### P7.2 Standardize naming incrementally

**Problem:** Public and internal identifiers mix camelCase with Zig snake_case.

**Why it matters:** Inconsistent naming makes APIs harder to scan and encourages
new code to follow conflicting precedents.

**Actions:**

1. Record snake_case as the convention for functions, variables, and fields.
2. Create a list of public camelCase compatibility APIs.
3. Add snake_case names when each subsystem is otherwise modified.
4. Keep temporary aliases only where they reduce migration risk.
5. Remove aliases after all in-repository callers migrate.
6. Avoid standalone mass-renaming commits that obscure functional history.

**Done when:** New code follows one convention and touched subsystems no longer
introduce camelCase identifiers.

#### P7.3 Add a top-level project README

**Problem:** Repository-level status and entry commands are spread across
component READMEs and internal documentation.

**Why it matters:** New contributors cannot quickly discover project goals,
supported targets, current maturity, or the normal validation workflow.

**Actions:**

1. Add `/README.md` with the microkernel goal and current maturity statement.
2. Document toolchain and external boot/QEMU dependencies.
3. List build, test, run, documentation, and architecture-selection commands.
4. Link repository layout, component workflow, coding rules, object-model design,
   and this assessment.
5. Include a concise implemented/partial/planned status table.
6. Avoid duplicating the detailed roadmap from this document.

**Done when:** A fresh contributor can build and understand the project from the
repository root without first searching component documentation.

#### P7.4 Keep initialization code executable and testable

**Problem:** Active initialization has been extracted into
`kernel_initialization.zig` and is host tested, but `kernelMain()` still contains
a large commented PMM/heap experiment and disabled duplicate initialization
steps.

**Why it matters:** The remaining comments preserve an obsolete kernel-owned
allocation direction, obscure the active boot order, and are not checked by the
compiler.

**Actions:**

1. Keep `kernel_initialization.initialize()` as the single active orchestration
   path up to user entry.
2. Delete the commented PMM, heap, duplicate boot-finalization, interrupt, and
   allocation-probe blocks.
3. Preserve architectural intent in this assessment or a reviewed design document,
   not disabled source.
4. Keep control flow and fatal-boundary decisions in one parent function.
5. Extend existing host orchestration tests whenever an initialization stage is
   added.
6. Emit concise stage-specific diagnostics only at the top-level boundary.

**Done when:** `kernelMain()` is a thin wrapper over compiled, testable stages and
contains no disabled implementation blocks.

## Recommended next vertical slice

The phased implementation plan for multiple processes is maintained in
the [userspace process roadmap](userspace-process-roadmap.md).

Avoid adding a kernel PMM or heap. Complete one narrow seL4-style memory-authority
path end to end:

1. finish **P0.4** so the syscall boundary has an explicit current caller;
2. define the physical-range/untyped capability and boot handoff from **P3.1**;
3. let the root task select one delegated page through the initial allocator from
   **P3.2**;
4. retype that authority into one genuinely backed memory object from **P1.3**;
5. attach a hardware root to the target address-space object from **P1.2**;
6. map the object, write and read the page in user space, and verify shared backing;
7. represent the root task as the first thread and contain its exit through
   **P2.1** and **P2.2**;
8. extend the existing system-smoke protocol from **P5.4** on both architectures.

Completing this slice would prove that user space controls physical allocation
policy while the kernel enforces capability authority and mappings. It would also
prove that a registered thread can use genuinely backed memory and return control
to the kernel without halting the system.

## Bottom line

The project is ahead of a typical early hobby kernel because it has a real
userspace artifact boundary, ring-3 entry, shared ABI, ELF loader, separate page
tables, initial capability checks, architecture mocks, and organized tests.

Its primary risk is semantic overstatement: address spaces, memory objects, and
capabilities exist by name, but only the bootstrap root address space currently
has complete hardware state, memory objects do not yet own delegated backing, and
the root task has no physical-memory authority. The next architecture milestone
is not activation of a kernel PMM or heap; it is a capability-controlled handoff
of allocatable memory to a user-space resource manager, with bounded kernel
storage and complete mapping/lifetime semantics.
