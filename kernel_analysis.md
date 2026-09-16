# Current Kernel Assessment

Date: 2026-09-14

This document records a high-level assessment of the current repository state.
It is the single source of truth for implementation maturity and the prioritized
technical backlog. Evergreen project conventions remain in
`kernel-os-code-organization-best-practices.md` and
`zig-code-structure-best-practices.md`.

## Executive summary

The project is a credible early kernel bring-up environment with several strong
architectural foundations:

- architecture-independent code is separated from x86-32, x86-64, and mock
  implementations;
- architecture interfaces are checked at compile time;
- the user/kernel ABI and initial root task are independently scoped
  components;
- common memory, process-registry, and capability-table logic has host tests;
- x86-64 reaches ring 3, handles root-task system calls, and observes a clean
  root-task exit in the existing serial log.

The kernel is not yet a functioning microkernel in the seL4 sense. It has the
shape of an initial capability system, but many exposed objects currently hold
metadata rather than complete kernel resources. It has no thread model,
scheduler, IPC endpoints, blocking operations, capability derivation or
revocation, object destruction, or user-fault containment. The active boot path
also bypasses the physical memory manager and kernel heap.

The most accurate maturity description is:

> A well-structured x86 kernel bring-up environment with an initial
> capability-shaped userspace API, but not yet a microkernel execution model.

## Assessment basis

This assessment is based on inspection of the current tracked source, tests,
build configuration, x86-64 ELF artifacts, and existing serial/QEMU logs.

The existing x86-64 serial output demonstrates this sequence:

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

- the boundary-tag heap;
- PMM allocation and accounting basics;
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
API documentation, and launches QEMU. CI checks formatting, executes tests, and
builds both architectures with Zig 0.15.2.

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

#### P0.3 Extract a common system-call dispatcher

**Problem:** x86-32 and x86-64 interrupt files duplicate syscall decoding and
directly invoke capability and process policy.

**Why it matters:** Security-sensitive policy is duplicated, architecture code
depends on broad kernel modules, and host tests cannot exercise the real syscall
decision path.

**Actions:**

1. Define an architecture-neutral `SyscallRequest` containing a syscall number
   and a fixed array of machine-independent argument values.
2. Define a typed `SyscallResult` and ABI error mapping.
3. Add `src/common/syscall/main.zig` with one dispatcher entry point.
4. Move capability and process operation selection into the common dispatcher.
5. Keep only trap-frame register marshalling in each x86 interrupt module.
6. Pass caller identity into the dispatcher explicitly.
7. Replace ad hoc console error messages with returned error codes; retain
   optional structured diagnostics outside the hot path.
8. Add table-driven tests for every known syscall, unknown numbers, invalid
   handles, invalid rights, malformed flags, and range errors.

**Done when:** Both x86 implementations call the same tested dispatcher and
contain no capability/process policy beyond register conversion.

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

#### P1.3 Give memory objects real physical backing

**Problem:** A memory object records only owner and size. VMA fault resolution
ignores its handle and offset and allocates unrelated anonymous frames.

**Why it matters:** Mapping the same object twice does not provide shared memory,
so the memory-object abstraction currently validates only control-plane
metadata.

**Actions:**

1. Define a per-page backing entry with explicit uncommitted/committed state.
2. Choose a fixed-capacity backing representation suitable for the current
   no-general-heap boot stage.
3. Add a lookup from memory-object handle and page offset to backing entry.
4. Allocate and zero a physical frame on the first fault for an uncommitted page.
5. Reuse the committed frame for subsequent mappings and faults.
6. Validate object offset, page index, and permissions before allocation.
7. Roll back frame commitment when MMU mapping fails.
8. Track mapping or object references needed for safe destruction.
9. Add tests mapping one object into two address spaces and verifying the same
   physical frame is used.
10. Extend the root-task demonstration to write and read object-backed memory.

**Done when:** Memory-object identity determines physical backing and shared
mapping behavior is verified by host tests and QEMU.

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

### Priority 3: memory-management correctness and activation

#### P3.1 Make PMM initialization deterministic

**Problem:** The frame map is allocated uninitialized and populated only for
memory-map entries. Gaps in the firmware map may retain indeterminate state.

**Why it matters:** The allocator can interpret uninitialized metadata as free
physical memory.

**Actions:**

1. Initialize every tracked frame as used and reserved.
2. Validate each memory-map range for overflow and target address width.
3. Clamp or reject ranges beyond tracked physical memory explicitly.
4. Mark only complete frames in confirmed available regions as free.
5. Apply early reservations after available-region initialization.
6. Calculate totals from resulting frame states instead of raw region sizes.
7. Add tests with holes, overlapping entries, unaligned ranges, and ranges above
   the tracked limit.

**Done when:** Every frame has deterministic state and accounting matches an
independent scan of frame metadata for adversarial maps.

#### P3.2 Make PMM transitions atomic and accurately accounted

**Problem:** `reserve()` silently accepts out-of-range requests and updates
counters by requested range size instead of actual transitions. `free()` can
mutate frames before discovering a later invalid frame, and double frees can
inflate availability.

**Why it matters:** Incorrect physical-memory accounting can cause overlapping
allocations or eventual memory corruption.

**Actions:**

1. Add checked range construction shared by allocate, reserve, and free.
2. Return explicit errors for zero-size, overflow, and out-of-range operations.
3. Validate an entire range before changing any frame.
4. Define legal transitions between unavailable, free, allocated, and reserved.
5. Update counters only when a frame actually changes state.
6. Reject freeing reserved, unavailable, or already-free frames.
7. Remove `trackAllocationsAsReserved` or replace it with an explicit allocation
   purpose parameter.
8. Remove or deliberately integrate the unused `markFrames()` helper.
9. Add tests for duplicate reservation, overlap, partial failure, double free,
   reserved free, overflow, and fragmented allocation.

**Done when:** Every PMM operation is all-or-nothing and counters always equal
the state represented by the frame map.

#### P3.3 Activate PMM in the hardware boot path

**Problem:** The active boot path continues to use the monotonic early allocator
for root-task pages and page tables. PMM initialization and the transition flag
are commented out in `kernelMain()`.

**Why it matters:** Host-tested PMM behavior is not validated on hardware, and
all runtime allocations remain permanently reserved.

**Actions:**

1. Extract a fallible staged `kernelInitialize()` function.
2. Initialize the terminal and early reservations first.
3. Initialize PMM before creating runtime kernel objects.
4. Switch `earlyAllocatorActive` at one documented transition point.
5. Make MMU page-table allocation use PMM after that transition.
6. Preserve the early allocator only for resources that truly must be permanent.
7. Add rollback or explicit fatal boundaries for each initialization stage.
8. Remove the large commented experimental block from `kernelMain()`.
9. Add serial milestones and a QEMU assertion that PMM-backed allocations occur.

**Done when:** Normal root-task setup after the transition consumes PMM frames,
the early allocator no longer grows during runtime setup, and both architectures
still boot.

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

**Problem:** The x86-64 heap and reserved constants retain low 32-bit-style
addresses, below the declared higher-half kernel boundary. Direct-map constants
also mix a fixed legacy model with Limine's dynamic HHDM offset.

**Why it matters:** Enabling the heap or broader user mappings can create
kernel/user address collisions and contradictory range validation.

**Actions:**

1. Write a documented x86-64 virtual layout with user, guard, kernel image,
   direct map, heap, MMIO, and reserved regions.
2. Derive all boundary constants from that layout.
3. Treat Limine's HHDM offset and validated mapped extent as the direct map.
4. Remove or rename constants that do not describe active mappings.
5. Add compile-time canonical-address and non-overlap assertions.
6. Update linker, user-range validation, heap bounds, and kernel mapping clone
   assumptions together.
7. Add QEMU probes for the first and last page of each active region.

**Done when:** Every x86-64 virtual region is canonical, non-overlapping, and
used consistently by the linker, MMU, VMM, and process validator.

#### P3.7 Enable and validate the kernel heap

**Problem:** The generic heap is well tested, but the global kernel heap is not
initialized in the active boot path and has no explicit commit/decommit policy.

**Why it matters:** Kernel object growth cannot safely rely on dynamic allocation
until virtual reservation, physical commitment, and reclamation are separated.

**Actions:**

1. Move heap sizing policy out of architecture MMU implementations.
2. Reserve a non-overlapping kernel virtual heap range during staged boot.
3. Define whether pages are eagerly committed or faulted in on demand.
4. Initialize the global allocator only after backing pages are usable.
5. Keep normal `free()` local to heap metadata.
6. Add a separate, explicit page decommit policy for memory pressure.
7. Add accounting invariants for reserved, committed, and allocated bytes.
8. Add a QEMU allocation/free/coalescing smoke test behind a test build option.

**Done when:** Kernel objects can allocate after boot from a backed heap, normal
free does not implicitly manipulate page tables, and all three accounting values
remain consistent.

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

#### P5.1 Stabilize mock memory lifecycle

**Problem:** Mock `getMemoryMap()` allocates a new 64 MiB host region on each
call and does not free or explicitly own it.

**Why it matters:** Tests leak memory, depend on implicit setup, and can hide
lifecycle bugs.

**Actions:**

1. Add explicit `initializeTestMemory(size)` and `deinitializeTestMemory()`
   operations.
2. Make `getMemoryMap()` return stable state without allocation.
3. Make `resetForTest()` clear mappings and counters without leaking the backing
   region.
4. Detect use before initialization.
5. Update every PMM/VMM test to use a shared setup/teardown helper.
6. Add a repeated initialization/reset test and run it under Zig leak checking.

**Done when:** Repeated test runs allocate and release one intentional backing
region per fixture and memory-map reads are side-effect free.

#### P5.2 Make platform and interrupt mocks observable

**Problem:** Mock interrupt functions are no-ops and the mock writer discards
output.

**Why it matters:** Boot sequencing, interrupt state, acknowledgements, timer
configuration, and diagnostics cannot be asserted on the host.

**Actions:**

1. Track interrupt enabled/disabled state.
2. Store registered vector addresses and gate attributes.
3. Count acknowledgements per vector.
4. Record timer frequency and initialization count.
5. Buffer console bytes in fixed test storage.
6. Record color changes and console initialization.
7. Add reset and query helpers under test-only declarations.
8. Add host integration tests for initialization order and interrupt behavior.

**Done when:** Common boot/dispatch tests can assert all externally visible
platform and interrupt effects without QEMU.

#### P5.3 Expand ABI, ELF, and root-task tests

**Problem:** ABI tests cover basic layouts, ELF tests cover only non-ELF
rejection, and root-task tests check only shared constants.

**Why it matters:** Cross-domain binary contracts can regress while all current
tests still pass.

**Actions:**

1. Assert enum values, rights layout, syscall constants, and structure offsets.
2. Add valid ELF32 and ELF64 fixtures with multiple loadable segments.
3. Add truncated header/table, overflow, wrong machine/class/endian, empty
   segment, and overlapping-segment cases.
4. Validate entry points reside in an executable loadable segment.
5. Abstract the root-task syscall transport behind a comptime-injected backend.
6. Test every userspace wrapper's syscall number and argument order.
7. Test userspace translation of kernel success and failure results.

**Done when:** The shared ABI and root-task wrappers can change only with an
intentional corresponding test update.

#### P5.4 Add deterministic QEMU smoke tests

**Problem:** CI compiles both architectures but does not boot them.

**Why it matters:** Linker, boot protocol, descriptor-table, MMU, and ring-3
regressions are invisible to host tests.

**Actions:**

1. Add a non-daemonized, serial-only QEMU test configuration.
2. Add `isa-debug-exit` or an equivalent deterministic completion mechanism.
3. Emit stable machine-readable milestones rather than parsing verbose prose.
4. Enforce a timeout and kill QEMU on failure.
5. Fail on panic, triple fault, unexpected reset, or missing milestone.
6. Add separate x86-32 and x86-64 smoke build steps.
7. Keep interactive `run` and debugger-oriented launch behavior separate.
8. Run smoke tests in CI after unit tests and architecture builds.

**Done when:** CI proves both kernels boot, enter userspace, complete the chosen
scenario, and terminate QEMU with a success code.

#### P5.5 Remove redundant CI work and expose explicit verification steps

**Problem:** The architecture matrix runs the same host mock suite twice, while
compile-only and integration checks are not named separately.

**Why it matters:** CI spends time without increasing coverage and developers
lack clear fast versus comprehensive validation commands.

**Actions:**

1. Run host unit/component tests once outside the architecture matrix.
2. Keep architecture kernel/root-task builds in the matrix.
3. Add named `test-unit`, `test-components`, and `test-smoke` steps or document
   equivalent commands.
4. Add an explicit compile/check step if Zig's build API provides value beyond
   the normal builds.
5. Preserve one aggregate `tests` step for local convenience.
6. Document the expected validation sequence in the top-level documentation.

**Done when:** Each CI job has distinct coverage and local commands clearly
separate fast host checks from QEMU integration checks.

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

**Problem:** PMM, VMM, registries, diagnostics, and mocks use unprotected global
mutable state, and current execution state is implicitly uniprocessor.

**Why it matters:** Enabling additional CPUs or preemption without ownership and
locking rules would introduce races throughout the kernel.

**Actions:**

1. Document subsystem state ownership before adding application processors.
2. Introduce CPU-local current-thread and interrupt state.
3. Define lock primitives and interrupt-save semantics.
4. Establish and document a global lock order.
5. Add synchronization to PMM, capability spaces, object registries, and
   scheduler queues one subsystem at a time.
6. Keep the build explicitly single-CPU until those contracts are enforced.
7. Add application-processor startup only after synchronized scheduler state
   exists.

**Done when:** The kernel can explain and mechanically enforce who owns every
shared mutable structure before a second CPU executes kernel code.

### Priority 7: maintainability and documentation

#### P7.1 Remove dead or misleading x86-64 bootstrap code

**Problem:** `src/architecture/x86/64/mmu/early_boot.zig` contains comments and
assembly derived from a 32-bit multiboot paging path and is unused by the active
x86-64 Limine flow.

**Why it matters:** Zig's lazy analysis can leave invalid unused declarations
unnoticed, and maintainers may mistake the file for an active x86-64 mechanism.

**Actions:**

1. Confirm no supported x86-64 boot path calls the file.
2. Identify any genuinely reusable checked arithmetic helpers.
3. Move those helpers into an appropriately named common module with tests.
4. Delete the obsolete bootstrap implementation.
5. If a non-Limine path is required, replace it with a separately designed
   long-mode implementation rather than retaining copied 32-bit code.
6. Add a source/reference check ensuring architecture entry points are reachable
   from supported build configurations.

**Done when:** Every x86-64 MMU source file represents an active, build-checked
mechanism or a clearly documented shared helper.

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

**Problem:** `kernelMain()` contains a large commented experimental
initialization sequence.

**Why it matters:** Commented code drifts, obscures the active boot order, and is
not checked by the compiler.

**Actions:**

1. Extract active initialization into small fallible stages.
2. Keep control flow and fatal-boundary decisions in one parent function.
3. Move allocation probes into host tests or a build-gated QEMU self-test.
4. Delete obsolete commented code after preserving any required intent in issue
   text or design documentation.
5. Add host tests for architecture-independent initialization sequencing using
   observable mocks.
6. Emit concise stage-specific diagnostics only at the top-level boundary.

**Done when:** `kernelMain()` is a thin wrapper over compiled, testable stages and
contains no disabled implementation blocks.

## Recommended next vertical slice

Avoid broad syscall or driver expansion. Complete one narrow path end to end:

1. complete **P0.3** and **P0.4** so syscall dispatch and caller identity are
   explicit and host-testable;
2. complete the root-address-space registration portion of **P1.2**;
3. complete one-page physical backing from **P1.3**;
4. represent the root task as the first thread from **P2.1**;
5. implement contained exit to an idle context from **P2.2**;
6. access the object-backed page from userspace through the safe-copy boundary
   in **P0.1**;
7. validate the entire sequence with the x86-64 portion of **P5.4**.

Completing this slice would prove that a registered thread can use capability-
authorized, genuinely backed memory and return control to the kernel without
halting it. That would move the project from a capability-themed prototype to
the beginning of a genuine microkernel execution environment.

## Bottom line

The project is ahead of a typical early hobby kernel because it has a real
userspace artifact boundary, ring-3 entry, shared ABI, ELF loader, separate page
tables, initial capability checks, architecture mocks, and organized tests.

Its primary risk is semantic overstatement: address spaces, memory objects, and
capabilities exist by name, but only the bootstrap root address space currently
has complete hardware state, and memory objects do not yet own backing memory.
The priority backlog above deliberately favors completing and securing those
semantics before adding breadth.