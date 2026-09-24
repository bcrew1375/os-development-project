# Userspace Process Roadmap

Status date: 2026-09-24

This document is the implementation plan for progressing from the bootstrapped
root task to multiple isolated, useful userspace processes. The architectural
motivation and broader priorities remain in
the [current kernel assessment](kernel-assessment.md). The testing strategy
remains in the [testing roadmap](testing-roadmap.md).

The roadmap follows a seL4-style ownership boundary:

- the kernel provides protected objects, capability enforcement, address-space
  mechanisms, execution, scheduling, IPC, and fault isolation;
- the root task owns process-construction policy, physical-memory allocation
  policy, executable loading, userspace heaps, and service orchestration;
- the kernel does not gain a general-purpose PMM or heap as part of this work;
- retained kernel storage is bounded or explicitly funded through capabilities.

## Status legend

- `[ ]` — not started
- `[~]` — in progress
- `[x]` — complete
- `[!]` — blocked; the item must name its blocker

When an item is completed, record its completion date, validation commands, and
any deliberate limitation.

## Current baseline

The current system already provides several foundations. The root task is a
real initial userspace process, but it is not yet a normal schedulable child
process created through the runtime object model.

- the kernel loads and enters one freestanding root-task ELF;
- x86-32 and x86-64 have separate hardware page-table roots for the root task;
- the shared ABI exposes debug output, exit, address-space creation,
  memory-object creation, and mapping requests;
- common syscall policy is architecture independent and host tested;
- capability handles enforce owner, object-type, rights, generation, and stale-handle checks;
- native, physical architecture, and production system-smoke tests run in CI.

The current objects are not sufficient for multiple processes:

- syscall caller identity is hard-coded to the root process;
- registered address-space objects do not own hardware roots;
- memory objects contain metadata but no delegated physical backing;
- capability slots are global and cannot yet be copied, attenuated, or revoked;
- there are no thread objects, runnable queues, context switches, or IPC objects;
- user faults and process exit can still halt the system.

## Target process model

Initially, a process is a userspace policy concept grouping three kernel object
relationships:

```text
Userspace process record
+-- capability-space capability
+-- address-space capability
+-- one or more thread capabilities
+-- parent/process-manager endpoint capability
+-- executable and lifecycle metadata owned by the process manager
```

A separate first-class kernel `Process` object is not required for the first
implementation. The root task or a later process-manager service may own process
IDs, parent-child relationships, names, executable metadata, and service policy.
The kernel must not infer authority from those userspace records.

## Rules for all phases

1. Preserve the ABI boundary: the root task imports only the shared ABI.
2. Keep architecture-independent policy under `src/common`.
3. Keep x86 implementations behind compile-time-checked architecture interfaces.
4. Do not introduce a general kernel PMM, heap, or implicit frame-allocation
   syscall.
5. Use fixed-capacity kernel storage until capability-funded object storage is
   designed and reviewed.
6. Make every multi-object operation transactional or define an explicit partial
   result that userspace can safely unwind.
7. Check arithmetic, alignment, target-width conversion, and range boundaries.
8. Do not accept userspace pointers without checked copy helpers.
9. Keep kernel-mode faults fatal and contain user-mode faults to the responsible
   thread or protection domain.
10. Add native policy tests before physical QEMU tests where practical.
11. Verify architecture mechanisms on both x86-32 and x86-64.
12. Extend the existing versioned test protocols instead of parsing prose output.
13. Define ownership, lifetime, and lock rules before enabling preemption or SMP.
14. Keep process creation in the root task; kernel syscalls create and configure
    individual protected objects rather than a policy-heavy process bundle.

## Dependency overview

```text
Phase 1: identities and authorization
    |
    v
Phase 2: real address-space objects
    |
    v
Phase 3: userspace physical-memory authority
    |
    v
Phase 4: threads, scheduling, and a second process
    |
    v
Phase 5: IPC and useful process services
```

Some implementation work may overlap, but a phase exit gate must be satisfied
before the next phase is treated as operationally complete.

## Immediate target: the first child process

The existing root task already demonstrates the first userspace transition. The
next milestone is the first independently created child process, not another
bootstrap-only ring-3 transition. The shortest useful vertical slice is:

1. explicit current execution context;
2. checked userspace copy operations;
3. user-fault containment;
4. address-space objects that own hardware roots;
5. one cooperative thread-switch path;
6. real backing for the child memory object;
7. root-task ELF loading and child exit while the root task continues.

SMP, timer preemption, general IPC, and a full userspace service model remain
later work unless a dependency requires them sooner.

# Phase 1 — Establish execution identity and authorization

**Objective:** Make the currently running userspace context explicit so every
syscall and fault can be attributed to the correct thread, capability space, and
address space.

This phase does not create a second runnable process. It removes the global-root
identity assumption that would otherwise invalidate all later isolation work.

## [x] U1.1 Define the kernel object and lifetime contract

- Completed: 2026-09-22
- Validation: documentation review; Markdown link check; `git diff --check`
- Limitation: this completes the design contract only; the named kernel objects
  remain implementation work in later phases.

**Related assessment:** P1.1.

**Work:**

- maintain `docs/kernel-object-model.md`;
- define `Thread`, `AddressSpace`, `CapabilitySpace`, `MemoryObject`, untyped or
  physical-range authority, `Endpoint`, and `Notification` responsibilities;
- define whether kernel objects are referenced by stable object IDs, internal
  pointers, or slot-plus-generation handles;
- define object ownership separately from capability possession;
- define reference, deletion, revocation, destruction, and reclamation rules;
- define which operations are kernel mechanisms and which are root-task policy;
- define fixed-capacity limits and explicit exhaustion behavior;
- document the initial uniprocessor ownership model and the path to CPU-local
  state and synchronization.

**Acceptance criteria:**

- each object has a named owner for its mutable kernel state;
- capability deletion and object destruction are explicitly different operations;
- no design step assumes a kernel-global PMM or heap;
- future thread, address-space, and capability-space implementations can cite one
  reviewed contract.

**Validation:** Documentation review, Markdown checks, and `git diff --check`.

## [x] U1.2 Introduce explicit execution-context state

- Completed: 2026-09-22
- Validation: `zig build tests`; architecture syscall ABI tests on x86-32 and
  x86-64; `zig fmt --check`; `git diff --check`
- Limitation: the current context uses fixed bootstrap identities and a single
  uniprocessor storage location; CPU-local state and normal thread objects remain
  later work.

**Related assessment:** P0.4 and P2.1.

**Kernel work:**

- define an architecture-neutral execution-context record containing at least:
  - current thread identity;
  - current capability-space identity;
  - current address-space identity;
- register the bootstrapped root task as the first execution context;
- store the current context in one clearly owned uniprocessor location;
- provide a narrow accessor for syscall and exception entry;
- define initialization and invalid-state behavior;
- document replacement by CPU-local storage before SMP.

**Architecture work:**

- keep trap entry independent of process policy;
- pass the current execution identity into common syscall dispatch;
- preserve enough trap-frame information to attribute user faults to the context.

**Acceptance criteria:**

- the root task is represented by explicit current-context state before user entry;
- syscall dispatch receives identity from the current context;
- use before context initialization fails as a kernel invariant violation;
- the context API does not expose architecture trap-frame layouts to common code.

## [x] U1.3 Remove root-process identity from syscall authorization

- Completed: 2026-09-22
- Validation: `zig build tests`; architecture syscall ABI tests on x86-32 and
  x86-64; both production system-smoke tests; `zig fmt --check`; `git diff --check`
- Limitation: capability handles remain global fixed-capacity handles without
  generations or per-process capability spaces; those are U1.4 and later work.

**Related assessment:** P0.4.

**Work:**

- remove direct `ROOT_PROCESS_HANDLE` use from both x86 syscall handlers;
- resolve capabilities in the current capability space or, during migration, with
  the current execution-domain identity;
- remove root-owner convenience paths from production syscall policy;
- retain narrowly scoped bootstrap helpers only where needed before user entry;
- test at least two synthetic callers against the same handle values.

**Acceptance criteria:**

- no architecture syscall path supplies a constant caller identity;
- a capability owned by one synthetic caller is rejected for another;
- changing current context changes authorization without changing syscall input;
- current root-task behavior remains unchanged.

## [x] U1.4 Define stable capability-handle semantics

- Completed: 2026-09-22
- Validation: ABI component tests; `zig build tests`; architecture tests on
  x86-32 and x86-64; both production system-smoke tests; `zig fmt --check`;
  `git diff --check`
- Limitation: lookup remains owner-based transitional isolation; capability
  spaces, derivation, transfer, and revocation remain later work.

**Related assessment:** P1.4.

**Work:**

- choose slot-plus-generation or another reviewed stale-handle-safe format;
- define invalid-handle and generation-wrap behavior;
- separate object identity from capability-slot identity;
- define per-capability rights and optional badge/metadata needs;
- define whether handle width remains `u32` on both architectures;
- add ABI assertions for layout and reserved values.

**Acceptance criteria:**

- a deleted and reused slot cannot make an old handle valid;
- capability lookup is scoped to the caller's capability space;
- handle representation is architecture independent;
- exhaustion returns an explicit error rather than reaching `unreachable`.

## [x] U1.5 Add safe userspace copy primitives

- Completed: 2026-09-22
- Validation: `zig build tests`; x86-32 and x86-64 architecture tests;
  both production system-smoke tests; `zig fmt --check`; `git diff --check`
- Limitation: checked copies use a bounded fixed kernel buffer and the current
  address-space/MMU lookup path; user-fault containment and independently
  activatable child address spaces remain later phases.

**Related assessment:** P0.1.

**Kernel work:**

- define `UserAddress`, `UserSlice`, or equivalent non-pointer representations;
- add checked range construction with overflow and kernel-boundary rejection;
- query every page for presence, user access, and required permissions;
- implement bounded `copyFromUser` and `copyToUser` operations;
- define recoverable behavior for faults during a checked copy;
- update `debug_write` to copy through a fixed kernel buffer.

**Acceptance criteria:**

- no syscall adapter directly dereferences a userspace-supplied integer;
- invalid, cross-page, kernel-space, overflowing, and oversized ranges return
  defined errors;
- valid copies work in both registered address spaces used by tests.

## Phase 1 testing

### Native tests

- current-context initialization and reset;
- two-caller authorization isolation;
- stale-handle rejection and generation behavior;
- capability-table exhaustion;
- valid and invalid user-range construction;
- cross-page copy behavior and injected lookup failures.

### Physical tests

- syscall authorization uses the installed execution context on both x86 targets;
- checked user copy succeeds for valid mapped memory;
- hostile pointers do not panic or halt the kernel.

### Validation commands

```sh
zig build tests
zig build coverage
zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64
zig build system-smoke -Darch=x86_32
zig build system-smoke -Darch=x86_64
```

## Phase 1 exit gate

- [x] The root task has an explicit execution context.
- [x] Syscall authorization contains no hard-coded root identity.
- [x] Two caller identities have isolated capability lookup.
- [x] Stale handles are rejected after slot reuse.
- [x] All syscall user-pointer access uses checked copy primitives.
- [x] Existing production smoke tests still pass on both architectures.

**Phase 1 completed:** 2026-09-22.

**Exit validation:** `zig build tests`; `zig build architecture-tests
-Darch=x86_32`; `zig build architecture-tests -Darch=x86_64`; `zig build
system-smoke -Darch=x86_32`; `zig build system-smoke -Darch=x86_64`;
`zig fmt --check`; `git diff --check`.

**Known validation limitation:** `zig build coverage` currently fails in the
existing coverage runner because it uses two APIs incompatible with the Zig
toolchain installed in this workspace (`std.debug.SelfInfo.Elf.open` and the
`dumpStackTrace` argument shape). The ordinary native test suite remains green.

# Phase 2 — Make address spaces complete kernel objects

**Objective:** Ensure every address-space capability refers to an independently
activatable, mappable, and destructible hardware address space.

## [x] U2.1 Attach hardware roots to address-space objects

- Completed: 2026-09-22
- Validation: `zig build tests`; `zig fmt --check`; `git diff --check`; native
  architecture builds and physical architecture tests on x86-32 and x86-64
- Limitation: address-space roots are now owned by registered objects, but root
  task registration, explicit-root process mapping integration, root destruction,
  and physical-memory delegation remain U2.2-U2.5 and later phase work.

**Related assessment:** P1.2.

**Kernel work:**

- add `arch.AddressSpaceRoot` to the internal address-space object;
- initialize hardware root and VMA storage as one fallible operation;
- clone or install only the required kernel mappings;
- make object-slot reservation, root creation, and initialization transactional;
- define the maximum number of address spaces and explicit exhaustion behavior.

**Acceptance criteria:**

- every live address-space object owns exactly one hardware root;
- a failed creation leaves no used object slot or leaked root;
- two address-space objects map the same virtual address independently;
- capability resolution reaches the object and its root without global state.

## [x] U2.2 Register the root task through the normal object path

- Completed: 2026-09-23
- Validation: native tests; root-task component tests; x86-32 and x86-64 builds;
  full physical architecture tests and architecture coverage on both x86 targets
- Result: bootstrap registers the root hardware root in the bounded address-space
  table, installs its process-owned capability, and initializes the execution
  context with the same authoritative object handle used by runtime syscalls.

**Work:**

- register the bootstrapped root-task root as an address-space object;
- install its capability in the root capability space;
- associate the initial execution context with that object;
- remove the independent root-address-space metadata/handle split;
- keep bootstrap-only construction isolated from normal runtime creation.

**Acceptance criteria:**

- the root task uses the same address-space object interface as later processes;
- there is one authoritative root-task address-space identity;
- syscall mapping operations target the registered root-task object.

## [x] U2.3 Complete explicit-root mapping operations

- Completed: 2026-09-23
- Validation: native VMM/process/syscall tests and physical x86-32/x86-64 tests
  for explicit-root translation, root switching, isolation, permissions, and
  repeated low-level unmap
- Semantics: process policy operations require exact VMA ranges; repeated policy
  unmap returns `mapping_not_found`, while architecture page unmap is idempotent
  and returns the prior physical mapping when one existed. x86-32 reports pages
  executable because this target does not currently enable NX enforcement.

**Related assessment:** P3.4 and P3.5.

**Architecture and VMM work:**

- make map, protect, query, and unmap operations accept an explicit root;
- define absent-table, absent-page, repeated-unmap, and partial-range semantics;
- return the prior physical mapping where reclamation needs it;
- validate a complete requested range before mutation where atomicity is required;
- report effective architecture permission capabilities, including x86-32 NX
  limitations;
- reject unsupported security-sensitive permission combinations explicitly.

**Acceptance criteria:**

- the kernel can populate a non-current address space;
- unmapping one root cannot affect another root;
- permission queries match effective hardware behavior;
- repeated unmap follows one documented result on mock, x86-32, and x86-64.

## [x] U2.4 Define address-space destruction

- Completed: 2026-09-23
- Validation: native process, capability, and syscall tests plus physical
  x86-32/x86-64 cross-root unmap/destruction isolation tests
- Limitation: the current execution-context model tracks one active thread, so
  destruction rejects that active address space; checking all running or runnable
  thread references is deferred until general thread tracking exists.
- Deferred reclamation: destruction clears bounded VMA/object metadata and
  invalidates the capability generation, but owned physical frames and lower-level
  x86 page-table frames are not reclaimed. Their ownership and reclamation are
  deferred to Phase 3 physical-memory delegation.

**Kernel work:**

- reject destruction while a running or runnable thread references the space;
- remove mappings and release mapping references transactionally;
- reclaim owned lower-level page tables or record deferred reclamation explicitly;
- invalidate the capability and generation safely;
- define behavior when destruction encounters inconsistent mappings;
- make cleanup bounded and non-allocating.

**Acceptance criteria:**

- a destroyed address-space handle becomes stale;
- no thread can resume with a destroyed root;
- shared memory-object backing is not freed merely because one mapping disappears;
- all kernel-owned address-space metadata returns to its bounded pool.

## [x] U2.5 Add root-task address-space wrappers

- Completed: 2026-09-23
- Validation: root-task host tests verify lifecycle syscall numbers, argument
  ordering, permission results, and every structured ABI error translation
- Result: transport-injectable typed wrappers expose current/create/map/protect/
  query/unmap/destroy operations, and startup maps into its registered current
  address space instead of creating an unused second address space.

**ABI and root-task work:**

- expose typed wrappers for create, map, protect, unmap, and destroy as operations
  become available;
- return structured ABI errors instead of only generic success/failure where
  userspace must recover;
- keep wrappers transport-injectable for host tests;
- avoid exposing architecture page-table details to userspace.

**Acceptance criteria:**

- wrapper tests verify syscall number, argument ordering, and error translation;
- root-task policy code can construct an empty child address space without direct
  kernel imports.

## Phase 2 testing

### Native tests

- transactional address-space creation failures at each stage;
- root registration and object identity;
- explicit-root mapping isolation;
- permission capability validation;
- destruction with live references, stale handles, and shared mappings;
- bounded-pool exhaustion and reuse.

### Physical tests

- create and populate a second non-current hardware root;
- switch to it and observe the expected mapping;
- switch back and verify isolation;
- unmap and destroy it without corrupting the root task.

### Validation commands

Use the Phase 1 commands and architecture coverage for changed MMU code:

```sh
zig build architecture-coverage -Darch=x86_32
zig build architecture-coverage -Darch=x86_64
```

## Phase 2 exit gate

- [x] Every address-space capability identifies a hardware root.
- [x] The root task is registered through the normal address-space object path.
- [x] Non-current address spaces can be mapped, queried, protected, and unmapped.
- [x] Address-space destruction has defined reference and reclamation behavior,
  with physical-frame and lower-level page-table reclamation deferred to Phase 3.
- [x] Cross-root isolation is verified natively and under QEMU.

# Phase 3 — Delegate physical-memory policy to userspace

**Objective:** Give the root task non-forgeable authority over safe physical
memory and enough userspace policy to allocate, retype, map, and reclaim it.

The kernel validates and enforces authority. The root task decides how memory is
partitioned and used.

## [x] U3.1 Normalize allocatable physical-memory ranges

- Completed: 2026-09-23
- Validation: `zig build tests`; `zig build coverage`; both production builds;
  both `architecture-tests`; both `architecture-coverage`; both production
  `system-smoke` tests; `zig fmt --check`; `git diff --check`
- Limitation: normalization delegates only ordinary RAM. Device-memory authority
  and reclamation of firmware/bootloader ranges remain later policy work.

**Related assessment:** P3.1.

**Kernel boot work:**

- validate boot memory-map ordering, sizes, overflow, and target-width limits;
- page-align candidate available ranges conservatively;
- subtract kernel image, active page tables, boot modules, framebuffer/MMIO,
  firmware, bad memory, and retained bootloader data;
- merge only compatible adjacent ranges;
- reject overlaps or contradictory classifications;
- produce a deterministic range set on both architectures.

**Acceptance criteria:**

- no delegated range intersects a reserved range;
- range normalization is deterministic for equivalent input maps;
- adversarial holes, overlaps, unaligned ranges, and width overflow are tested;
- the kernel can explain every non-delegated physical range.

## [x] U3.2 Extend the boot and capability ABI for memory authority

- Completed: 2026-09-23
- Validation: ABI and root-task component tests; `zig build tests`;
  `zig build coverage`; both production builds; both `architecture-tests`;
  both `architecture-coverage`; both production `system-smoke` tests;
  `zig fmt --check`; `git diff --check`
- Limitation: bootstrap authorities are immutable root untyped-memory objects;
  subdivision, retyping, derivation tracking, and revoke remain U3.3.

**ABI work:**

- add a physical-range or untyped-memory object type;
- define fixed-layout descriptors with physical start, size, and memory attributes;
- define capability discovery through `BootInfo`, a bounded descriptor mapping, or
  an enumeration operation;
- bump the boot-info ABI version when layout or interpretation changes;
- define x86-32 behavior for physical addresses wider than userspace `usize`;
- add layout, enum-value, bounds, truncation, and version tests.

**Acceptance criteria:**

- userspace receives descriptors and matching capabilities;
- descriptors alone do not authorize mapping or retyping;
- capabilities cannot name reserved or out-of-range memory;
- boot-info parsing rejects unsupported versions safely.

## [x] U3.3 Implement untyped-memory derivation and retyping

- Completed: 2026-09-23
- Validation: ABI and root-task component tests; `zig build tests` (146 tests);
  `zig build coverage` (546/546 common lines, 100%); both production builds;
  both `architecture-tests`; both `architecture-coverage`; both production
  `system-smoke` tests; `zig fmt --check`; `git diff --check`
- Limitation: typed physical frames are authority leaves only. Attaching frames to
  immutable memory-object backing and mapping them remains U3.4.

**Related assessment:** P1.3 and P1.4.

**Kernel work:**

- represent root physical authority as one or more untyped-memory objects;
- support aligned subdivision into child untyped ranges or frame-backed objects;
- reject overlapping derivations;
- record parent-child derivation relationships;
- make retype and destination-slot installation atomic;
- define revoke/delete behavior and when physical authority becomes reusable;
- support at least normal RAM frames before device-memory objects.

**Acceptance criteria:**

- the same physical byte cannot back two independently derived exclusive objects;
- failed retype leaves source authority and destination slots unchanged;
- rights can only be preserved or attenuated;
- revocation invalidates descendants and permits defined reuse.

## [x] U3.4 Give memory objects immutable physical backing

- Completed: 2026-09-23
- Validation: ABI and root-task component tests; `zig build tests` (152 tests);
  `zig build coverage` (580/580 common lines, 100%); both production builds;
  both full `architecture-tests`; both `architecture-coverage`; both default
  production `system-smoke` tests; `zig fmt --check`; `git diff --check`
- Result: typed physical-frame capabilities are converted in place into immutable
  memory objects, normal RAM is zeroed before exposure, explicit-root mappings
  eagerly install exact backing frames transactionally, repeated mappings alias the
  same frames, mapping references govern destruction, and ancestor revoke forcibly
  unmaps and destroys descendant objects.
- Limitation: legacy anonymous VMAs retain their existing demand-allocation path;
  root-task physical allocation policy remains U3.5 and retirement of anonymous
  kernel PMM/early-allocation fallback remains U3.7.

**Related assessment:** P1.3.

**Kernel work:**

- store backing physical range, size, attributes, and derivation identity;
- remove implicit physical allocation from mapping and fault paths;
- map object pages by object offset into explicit address-space roots;
- reuse the same backing for every mapping of the same object page;
- zero normal RAM before first exposure unless the ABI explicitly requests and
  authorizes another initialization policy;
- reject incompatible cache, device, and executable attributes;
- roll back mapping references when MMU installation fails.

**Acceptance criteria:**

- one object mapped twice resolves to the same physical frames;
- two distinct exclusive objects cannot overlap physically;
- no runtime memory-object path calls a kernel-global PMM;
- mapping failure does not leak references or consume authority incorrectly.

## [x] U3.5 Implement the root-task physical-range allocator

- Completed: 2026-09-23
- Validation: ABI and root-task component tests; `zig build tests` (152 kernel
  tests plus host and component suites); `zig build coverage` (580/580 common
  lines, 100%); both production builds; both full `architecture-tests`; both
  `architecture-coverage`; both production `system-smoke` tests, including the
  ordered `physical_memory_allocated` milestone; `zig fmt --check`;
  `git diff --check`
- Result: the root task now owns a bounded first-fit physical-range allocator with
  checked absolute-address alignment, split and same-parent coalescing, byte
  accounting, transactional metadata exhaustion, and allocator/slot/generation
  checked handles. Startup allocates its managed page through this policy, retypes
  the selected parent capability and offset, and releases allocator metadata only
  after successful kernel-object cleanup.
- Limitation: this allocator supplies physical ranges, not general-purpose virtual
  memory. Building a userspace heap remains U3.6, and legacy anonymous kernel
  PMM/early-allocation paths remain until U3.7.

**Root-task work:**

- add a cohesive userspace memory-management subsystem;
- ingest delegated range descriptors and capability handles;
- implement checked aligned allocation and subdivision;
- track free, allocated, and delegated ranges without kernel-private imports;
- define explicit free/coalescing behavior;
- return typed exhaustion, invalid-free, overlap, and alignment errors;
- keep policy replaceable behind a concrete root-task-owned interface.

**Acceptance criteria:**

- holes and reserved ranges are never returned;
- split and coalescing preserve total byte accounting;
- duplicate and foreign frees are rejected;
- metadata exhaustion is explicit and leaves allocator state unchanged.

## [x] U3.6 Build a userspace heap on mapped memory

- Completed: 2026-09-24
- Validation: root-task component tests (25 tests); `zig build tests` (135 kernel
  tests plus host and component suites); `zig build coverage` (540/540 common
  lines, 100%); both root-task target builds; both production builds; both
  `architecture-tests`; both `architecture-coverage`; both production
  `system-smoke` tests with the ordered `userspace_heap_verified` milestone;
  linker `PT_LOAD` page-range inspection; `zig fmt --check`; `git diff --check`
- Result: the root task now owns a fixed-capacity multi-extent heap over the
  linker-defined `[__root_heap_start, __root_heap_end)` range. Each extent is
  funded through delegated physical allocation, frame retyping, memory-object
  creation, and explicit mapping before its checked boundary-tag allocator is
  published. Allocation is deterministic, growth and initialization roll back in
  reverse order, empty later extents can be reclaimed and retried after partial
  cleanup, and reclaimed virtual holes are reused.
- Limitation: extent metadata is currently capped at eight entries, the heap range
  is 16 MiB, and the initial 4 KiB extent remains mapped for the root task's
  lifetime. Concurrency control is deferred until root-task threading exists.

**Root-task work:**

- rehome or redesign useful allocator code from the experimental kernel heap;
- request/retype backing through the userspace physical allocator;
- map heap regions into the root-task address space through the ABI;
- separate virtual reservation, physical backing, and suballocation accounting;
- use explicit growth and reclamation policy;
- keep allocator failures recoverable.

**Acceptance criteria:**

- the root task can allocate and free general-purpose userspace memory;
- heap operations do not import or call kernel-private allocators;
- heap accounting remains consistent after split, coalesce, and exhaustion tests;
- kernel code gains no `kmalloc`-style interface.

## [x] U3.7 Retire legacy kernel PMM and heap paths

- Completed: 2026-09-24
- Validation: `zig build tests`; `zig build coverage`; both production builds;
  both full `architecture-tests`; both `architecture-coverage`; both production
  `system-smoke` tests; source-only retired-symbol scan; linker `PT_LOAD`
  page-range inspection; `zig fmt --check`; `git diff --check`
- Result: the experimental PMM, boundary-tag kernel heap, global heap facade,
  architecture heap-query APIs, `earlyAllocatorActive`, eager VMM allocation, and
  obsolete tests and compatibility exports are removed. Anonymous VMAs are now
  reservation-only and unbacked faults return `MissingPhysicalBacking`.
- Limitation: the kernel retains bounded bootstrap reservation for root ELF
  segments, a 64 KiB initial stack, boot information, and page-table construction.
  Runtime page tables use the 512-frame fixed pool with a 64-frame per-address-space
  limit; fixed-capacity object registries remain until capability-funded metadata
  storage is designed.

**Related assessment:** P3.3 and P3.7.

**Kernel cleanup:**

- inventory retained bootstrap allocations and establish hard upper bounds;
- remove dormant VMM fallback to `pmm.zig`;
- remove `earlyAllocatorActive` and obsolete transition code;
- remove production exports and aliases for the PMM and kernel heap;
- delete the commented PMM/heap experiment from `kernelMain()`;
- move reusable allocator code/tests to a userspace component or remove them;
- preserve only reservation and bounded bootstrap mechanisms needed by the kernel.

**Acceptance criteria:**

- production kernel code exposes no general-purpose PMM or heap API;
- every retained kernel allocation path is bounded and has exhaustion tests;
- physical-memory policy is exercised by root-task tests and system smoke;
- the normal kernel and root-task builds contain no accidental cross-domain import.

## Phase 3 testing

### Native tests

- physical-range normalization with adversarial maps;
- ABI layouts and version rejection;
- retype alignment, overlap, rollback, derivation, and revocation;
- shared physical backing across address spaces;
- root-task allocator split, coalesce, exhaustion, and invalid free;
- userspace heap allocation and accounting.

### Physical and system tests

- delegate one safe page to the root task on each architecture;
- retype it into a frame-backed memory object;
- map, write, read, unmap, and reclaim it;
- prove the physical address is stable across two mappings;
- emit versioned system-smoke milestones for delegation and backed access.

## Phase 3 exit gate

- [x] The root task receives non-overlapping physical-memory authority.
- [x] The root task can allocate one aligned page from that authority.
- [x] Retype creates a genuinely frame-backed memory object.
- [x] Shared mappings use the same physical backing.
- [x] The root task has a functioning userspace heap.
- [x] Production kernel paths no longer expose the experimental PMM or heap.

# Phase 4 — Create threads and run a second process

**Objective:** Let the root task construct a child protection domain, load an ELF,
start its initial thread, schedule it cooperatively, and contain its exit or fault.

## [ ] U4.1 Define the architecture-neutral thread object

**Related assessment:** P2.1.

**Kernel work:**

- define thread identity and `new`, `ready`, `running`, `blocked`, `faulted`, and
  `exited` states;
- associate each thread with one capability space and one address space;
- store exit status and user-fault information;
- define ownership of the kernel stack and saved architecture context;
- use fixed-capacity storage with explicit exhaustion;
- define legal state transitions as pure common policy where practical.

**Acceptance criteria:**

- invalid state transitions are rejected;
- a thread cannot become runnable without valid address and capability spaces;
- exited and faulted threads cannot be resumed accidentally;
- thread storage can be exhausted and reused without stale-handle acceptance.

## [ ] U4.2 Add architecture context creation and switching

**Architecture work:**

- define the saved register set for x86-32 and x86-64;
- create initial userspace context from entry point, stack pointer, flags, and
  argument convention;
- save and restore general-purpose, stack, instruction, flags, and segment state;
- switch address-space roots as part of thread switching;
- assign a bounded kernel stack to every runnable userspace thread;
- keep SIMD disabled until its state is explicitly supported;
- validate ABI stack alignment.

**Acceptance criteria:**

- switching away and back preserves all declared register state;
- a thread resumes in its own address space;
- initial entry reaches the configured userspace instruction and stack pointer;
- x86 implementations satisfy one common interface.

## [ ] U4.3 Implement a cooperative scheduler

**Related assessment:** P2.2.

**Kernel work:**

- add an idle context;
- add a fixed-capacity FIFO ready queue;
- define queue ownership and duplicate-enqueue protection;
- add a `yield` syscall;
- move a yielding running thread to ready state;
- select and switch to the next runnable thread;
- keep timer preemption disabled until cooperative switching is stable.

**Acceptance criteria:**

- two threads alternate repeatedly without register or address-space corruption;
- an empty ready queue selects idle safely;
- queue exhaustion and invalid state are explicit errors or kernel invariants;
- scheduler paths do not allocate dynamically.

## [ ] U4.4 Contain exit, invalid syscalls, and user faults

**Related assessment:** P0.2.

**Kernel work:**

- make `exit` record status and transition the current thread to `exited`;
- switch to the next runnable or idle thread instead of halting;
- return a defined unsupported-syscall result or fault only the caller;
- distinguish user-mode and kernel-mode exceptions at common dispatch;
- record page, protection, invalid-opcode, and general-protection faults on the
  responsible thread;
- reserve panic/halt for kernel faults and violated kernel invariants.

**Acceptance criteria:**

- child exit does not halt the root task or kernel;
- a malformed child cannot stop unrelated runnable threads;
- kernel faults remain fatal with useful diagnostics;
- fault records identify the responsible thread and relevant architecture data.

## [ ] U4.5 Add thread and capability-space configuration operations

**ABI work:**

- add object types and operations for capability-space and thread creation/retype;
- configure a thread's address space and capability space;
- set initial register state through fixed-layout architecture-neutral inputs;
- start, suspend, resume, and terminate a thread with explicit rights;
- prevent configuration after start unless a dedicated operation permits it;
- define structured error results.

**Acceptance criteria:**

- the root task can configure a child without kernel-private knowledge;
- configuration is rejected without management rights;
- start is atomic with the transition to the ready queue;
- wrapper transport tests cover argument order and errors.

## [ ] U4.6 Implement a userspace process manager and ELF loader

**Root-task work:**

- create a process record containing child object capabilities and lifecycle state;
- obtain executable bytes from a boot module initially;
- validate ELF through the shared parser;
- allocate/retype backing for loadable segments and the initial stack;
- temporarily map backing into the loader when copying is required;
- copy file bytes, zero BSS, and apply final permissions;
- construct startup information and initial stack contents;
- create the child capability space and install only selected capabilities;
- create, configure, and start the initial thread;
- unwind all created resources in reverse order on failure.

**Acceptance criteria:**

- ordinary child ELF loading occurs in userspace, not in a new kernel loader;
- executable, writable, and non-executable permissions match ELF policy and MMU
  capabilities;
- partial failure leaves no runnable thread and no untracked authority;
- process metadata remains root-task policy rather than kernel-global state.

## [ ] U4.7 Convert the root task to the normal thread path

**Work:**

- represent the root task as the first normal thread object;
- use the same saved-context representation used by child threads;
- retain only the minimum one-time boot transition required before scheduling;
- route root exit and faults through normal lifecycle handling;
- remove special-case assumptions from scheduler and syscall paths.

**Acceptance criteria:**

- the root task and child differ by authority and userspace policy, not by
  scheduler representation;
- root and child can yield to each other repeatedly;
- root exit selects idle or another runnable thread according to policy.

## Phase 4 testing

### Native tests

- thread state machine and storage exhaustion;
- ready-queue order, duplicate insertion, removal, and idle selection;
- child construction rollback at every resource-creation stage;
- ELF segment planning and initial stack construction;
- capability-space population and least-authority checks;
- exit and user-fault containment policy.

### Physical and system tests

- start two minimal userspace threads on each architecture;
- alternate through `yield` for a fixed number of rounds;
- verify private virtual mappings remain isolated;
- exit the child and continue executing the root task;
- trigger one controlled child fault and continue root execution;
- extend the system-smoke protocol with child start, yield, exit, and fault records.

## Phase 4 exit gate

- [ ] The root task is represented as a normal thread.
- [ ] A root-task process manager constructs a child from an ELF artifact.
- [ ] Root and child have separate address and capability spaces.
- [ ] Cooperative switching preserves context and isolation.
- [ ] Child exit and user faults do not halt the kernel.
- [ ] The process-construction path is transactional and tested.

# Phase 5 — Add IPC and useful process services

**Objective:** Allow isolated processes to communicate and receive delegated
authority so drivers and services can move out of the root task.

A second runnable process proves execution. IPC and capability transfer make that
process useful in a microkernel system.

## [ ] U5.1 Define the IPC ABI and endpoint object

**Related assessment:** P4.1.

**ABI and kernel work:**

- define a small fixed set of message registers;
- define endpoint send/receive rights;
- add an endpoint kernel object and capability type;
- implement non-blocking send and receive first;
- avoid userspace pointers in the first message format;
- define truncation, peer disappearance, and endpoint-destruction behavior;
- use fixed-capacity endpoint state.

**Acceptance criteria:**

- two threads exchange a bounded message without shared globals;
- endpoint authority is required for every operation;
- message delivery has defined all-or-nothing semantics;
- endpoint exhaustion is explicit and non-allocating.

## [ ] U5.2 Add blocking IPC and scheduler integration

**Kernel work:**

- add fixed-capacity sender and receiver wait queues;
- transition unmatched senders/receivers to `blocked`;
- wake the matching peer through the scheduler;
- define queue ordering and fairness policy;
- cancel blocked operations on thread exit, fault, capability deletion, or endpoint
  destruction;
- prevent lost wakeups under the initial uniprocessor model.

**Acceptance criteria:**

- blocked threads consume no runnable-queue slots;
- matching operations wake exactly the intended peer;
- cancellation removes stale wait-queue entries;
- a two-thread ping/pong test runs for many iterations.

## [ ] U5.3 Transfer capabilities through IPC

**Related assessment:** P4.2.

**Kernel and ABI work:**

- identify source and destination capability slots in the IPC contract;
- require transfer or grant authority from the sender;
- validate destination availability before delivery;
- allow rights attenuation but never amplification;
- update derivation relationships for transferred capabilities;
- make message and capability delivery atomic;
- roll back both sides on failure.

**Acceptance criteria:**

- a child receives a restricted capability from its parent;
- occupied destinations and insufficient rights leave both spaces unchanged;
- revoking the parent derivation invalidates transferred descendants as designed;
- stale or forged source handles are rejected.

## [ ] U5.4 Establish parent/process-manager communication

**Root-task work:**

- create a parent endpoint for every child;
- install only the child's endpoint capability and required startup capabilities;
- define initial request/reply messages for lifecycle and service discovery;
- track child state in userspace;
- define process-manager behavior for child exit, fault, and cleanup;
- avoid embedding POSIX semantics in the kernel ABI.

**Acceptance criteria:**

- a child announces startup and receives one service capability;
- the process manager observes exit or fault without polling kernel globals;
- child cleanup reclaims delegated capabilities and process-manager metadata.

## [ ] U5.5 Add fault delivery to userspace

**Kernel and ABI work:**

- define a fault message containing fault class, address, instruction pointer,
  access type, and architecture error data;
- allow a thread to name an authorized fault endpoint;
- block or suspend the faulting thread while delivering the message;
- define reply operations for resume, register modification, or termination;
- handle missing, full, or destroyed fault endpoints safely.

**Acceptance criteria:**

- the process manager receives a child's controlled fault;
- unrelated processes continue running;
- a fault reply can terminate the child cleanly;
- kernel-originated faults never route through userspace fault IPC.

## [ ] U5.6 Add notification objects for userspace drivers

**Related assessment:** P4.3.

**Kernel work:**

- define notification pending-bit or count semantics;
- bind an authorized interrupt source to a notification;
- signal from interrupt context without blocking or allocating;
- wake a waiting userspace thread;
- define mask, acknowledge, overflow, unbind, and destruction behavior;
- preserve an interrupt-controller-neutral interface.

**Acceptance criteria:**

- a userspace thread receives timer notification without kernel driver policy;
- notification signaling is bounded in interrupt context;
- unauthorized binding and waiting are rejected;
- PIC behavior remains functional while allowing future APIC routing.

## [ ] U5.7 Introduce the first userspace service split

**Root-task and component work:**

- choose one narrow service, preferably a test service rather than a hardware
  driver, for the first split;
- build it as an independent freestanding ELF component;
- have the process manager load it through the Phase 4 path;
- delegate only an endpoint and the memory authority it requires;
- expose a small request/reply protocol;
- add a client process or root-task client path;
- document extraction and component ownership boundaries.

**Acceptance criteria:**

- the service has no kernel-private imports;
- client and service communicate only through ABI-defined IPC;
- restarting or faulting the service does not halt the kernel;
- authority visible to the service is narrower than root-task authority.

## Phase 5 testing

### Native tests

- non-blocking and blocking endpoint behavior;
- wait-queue order, cancellation, and exhaustion;
- atomic message plus capability delivery;
- rights attenuation and revocation after transfer;
- fault-message construction and reply policy;
- notification accumulation and wakeup;
- process-manager cleanup state machine.

### Physical and system tests

- root and child complete IPC ping/pong on both architectures;
- parent transfers a restricted memory or endpoint capability;
- child faults and the parent receives a fault message;
- a userspace service starts, handles a request, exits, and can be restarted;
- a timer notification reaches a userspace thread.

## Phase 5 exit gate

- [ ] Processes exchange synchronous IPC messages.
- [ ] Blocking IPC integrates with scheduler state safely.
- [ ] Capabilities transfer atomically with rights attenuation.
- [ ] The process manager receives child lifecycle and fault events.
- [ ] At least one service runs in a separate userspace protection domain.
- [ ] Hardware events can reach an authorized userspace thread through a
      notification object.

# Post-roadmap work

The following work is important but should follow the five phases above unless a
phase exposes a blocking requirement:

- timer preemption and time-slice accounting;
- priority scheduling and priority-inversion policy;
- symmetric multiprocessing and CPU-local current-thread state;
- ACPI discovery, APIC, I/O APIC, and MSI routing;
- device-memory retyping and cache-attribute enforcement;
- a filesystem or executable-store service;
- demand paging and userspace pager policy;
- copy-on-write and shared-library mechanisms;
- process namespaces, credentials, or POSIX compatibility layers;
- asynchronous IPC optimizations and larger shared-memory payload protocols.

# First complete vertical milestone

The first milestone that spans all critical process-construction mechanisms is:

1. the root task receives one safe untyped-memory capability;
2. it allocates and retypes backing for a child ELF segment and stack;
3. it creates a child address space and capability space;
4. it maps and initializes the child image entirely through userspace policy;
5. it creates and starts the child thread;
6. root and child exchange one endpoint message;
7. the child exits with status zero;
8. the root task observes the exit and remains runnable;
9. both x86 system-smoke tests verify the ordered lifecycle.

This milestone proves the target division of responsibility: userspace controls
resource and process policy, while the kernel enforces authority, mappings,
execution, communication, and isolation.

# Roadmap maintenance

When updating this roadmap:

1. change an item's status marker;
2. add completion date, validation commands, and deliberate limitations;
3. update dependencies and phase exit gates;
4. update `kernel-assessment.md` if architecture or priority changed;
5. update `testing-roadmap.md` when new verification infrastructure is required;
6. keep ABI changes synchronized across the ABI library, kernel, root task, and
   their tests;
7. run the repository validation matrix appropriate to the changed mechanisms.
