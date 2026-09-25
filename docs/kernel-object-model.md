# Kernel Object Model

Status date: 2026-09-24

This document is the design contract for kernel objects that will support the
transition from the bootstrapped root task to multiple isolated userspace
processes. It defines intended ownership and lifetime rules; it does not claim
that every named object or operation is implemented.

The implementation roadmap is tracked in the [userspace process roadmap](roadmaps/userspace-process-roadmap.md).
The current implementation and its deliberate gaps are described in the [current
kernel structure](architecture/current-state.md) and [kernel assessment](roadmaps/kernel-assessment.md).

## Design boundary

The kernel provides protection mechanisms and bounded object state. The root task
provides process-construction and resource-allocation policy wherever privilege is
not required.

The kernel owns:

- address-space activation and page-table protection;
- thread execution state and context switching;
- capability authorization;
- physical-frame mapping and alias validation;
- endpoint and notification synchronization mechanisms;
- user-fault attribution and containment;
- bounded storage for live kernel objects.

The root task owns, subject to kernel authority:

- process records and process IDs;
- executable discovery and loading policy;
- physical-memory allocation policy;
- userspace heap policy;
- service startup and orchestration;
- parent/child policy and process naming.

A userspace record must never be treated as proof of kernel authority. Authority
comes from capabilities and the kernel objects they reference.

## Object relationships

For the initial design, a process is primarily a userspace policy record grouping
kernel object capabilities:

```text
userspace process record
+-- capability-space capability
+-- address-space capability
+-- one or more thread capabilities
+-- optional endpoint/notification capabilities
+-- executable and lifecycle metadata
```

A first-class kernel `Process` object is not required for the first child-process
milestone. The kernel must nevertheless retain enough execution-context state to
attribute every syscall, fault, and scheduling decision to a thread, address
space, and capability space.

## Object contracts

### Thread

A `Thread` is the unit of execution and scheduling.

The kernel owns:

- thread identity;
- lifecycle state: `new`, `ready`, `running`, `blocked`, `faulted`, or `exited`;
- the associated address space and capability space;
- the saved architecture context;
- a bounded kernel stack;
- exit status and user-fault information;
- scheduler membership.

A thread cannot become runnable until its address space, capability space, entry
point, stack, and initial register state are valid. An `exited` or `faulted` thread
cannot be resumed without an explicit, reviewed lifecycle operation.

The root task should ultimately be represented by the same normal thread model as
a child. One-time boot entry may remain special only until the first scheduler
transition is established.

### Address space

An `AddressSpace` owns one independently activatable hardware page-table root and
the common VMA metadata describing its authorized virtual ranges.

The kernel owns:

- the hardware root;
- VMA storage;
- mapping and protection validation;
- user/kernel range separation;
- mapping references and destruction state.

An address-space object must not be represented only by a handle or VMA metadata.
The root task's bootstrap address space must be registered through the same object
path used by later processes before the model is considered complete.

Destroying an address space requires that no running, ready, or blocked thread
references it. Destruction invalidates its capabilities and reclaims or explicitly
defers its page-table resources without freeing shared memory merely because one
mapping disappeared.

### Memory object

A `MemoryObject` represents backing that may be mapped into one or more address
spaces.

The kernel owns:

- object identity and size;
- alignment and range validation;
- physical-frame references or delegated memory authority;
- mapping permissions and alias checks;
- reference and destruction state.

The root task chooses which eligible physical authority funds a memory object. The
kernel must not silently allocate unrelated frames from an implicit general-purpose
kernel allocator as the steady-state behavior.

Mapping the same memory object twice must refer to the same backing. Destroying a
mapping must not destroy the object while another valid reference remains.

### Capability space

A `CapabilitySpace` is the namespace in which a task holds capabilities. Capability
slot identity is distinct from kernel object identity.

The kernel owns:

- slot allocation and lookup;
- object type and rights checks;
- generation or equivalent stale-handle protection;
- copy, mint, rights attenuation, transfer, deletion, and revocation semantics;
- exhaustion and invalid-handle behavior.

The current ABI encodes each local capability handle as a 32-bit value: the low
7 bits identify one of 128 slots and the upper usable bits identify a nonzero slot
generation while preserving the structured syscall-error bit. Handle zero is
reserved as invalid. Deleting a slot advances its generation before reuse, so a
stale handle cannot resolve to the new occupant.

The kernel currently stores up to 16 generation-checked capability-space objects.
Each space owns its own slot array; the active thread's capability-space handle
selects the namespace for syscall lookup. A local handle from one space therefore
has no authority in another space even when its numeric value is identical.

Slots retain object identity, rights, and an optional derivation parent containing
both capability-space and local-handle identity. Installation into another space
requires manage authority over that target and may only attenuate rights. Target
slots can be deleted through the target-space authority, and physical-memory
revocation follows derivation references across spaces.

Capability possession is not object ownership. A capability may grant restricted
authority without transferring ownership of the referenced object.

The bounded single-level spaces are an implemented intermediate model, not the
final seL4-style multi-level CSpace and IPC-transfer design.

### Endpoint

An `Endpoint` is a kernel synchronization object for synchronous IPC.

The kernel owns:

- wait queues;
- sender/receiver matching;
- bounded message-transfer state;
- blocking and wake-up transitions;
- capability-transfer validation.

The endpoint does not own process policy or service semantics. Message contents and
protocol meaning remain userspace concerns, subject to fixed ABI and transfer
validation.

### Notification

A `Notification` is a bounded asynchronous signal object used for events such as
interrupt delivery or one-way wakeups.

The kernel owns:

- pending-bit or counter state;
- wait and wake transitions;
- authorized signal and wait operations;
- interrupt binding and acknowledgement rules where applicable.

Notification signaling must be bounded, non-allocating, and safe from interrupt
context. It must not invoke userspace policy from the interrupt handler.

### Physical-memory authority

Physical-memory authority is the kernel-recognized right to consume or retype an
eligible physical range. It is not equivalent to a raw physical address supplied by
userspace.

The initial authority model must define:

- aligned range representation;
- ownership and delegation;
- non-overlap and consumption rules;
- retyping into frame or memory-object capabilities;
- revocation and reclamation;
- behavior at exhaustion.

The root task should receive bounded authority during bootstrap and use it to fund
child address spaces, stacks, executable segments, and userspace heaps.

The initial root-task allocator ingests validated, sorted normal-RAM descriptors
and retains each descriptor's parent capability and physical base. It uses bounded
sorted free extents plus generation-checked active allocation slots. Allocation is
checked first-fit with power-of-two alignment applied to absolute physical
addresses; returned ranges identify the parent capability, physical start,
parent-relative offset, and byte size. Free extents coalesce only when physically
adjacent and owned by the same parent capability.

Allocator handles are local policy identities, not kernel capabilities. They bind
the allocator instance, slot, generation, and an integrity guard so fabricated,
foreign, stale, and duplicate frees are rejected. Because allocator identity uses
its address, an allocator is initialized in its final storage and must not be moved
while handles remain live. Metadata exhaustion is explicit and failed operations
leave byte accounting and live allocation identities unchanged.

Userspace must delete the derived physical-frame capability or destroy the memory
object before returning its allocation handle to the allocator. If kernel cleanup
fails, the allocation remains reserved; advertising it as free would permit an
unsafe second derivation over still-live kernel authority.

### Frame-backed memory objects

A normal-RAM `MemoryObject` is created by atomically converting an existing typed
physical-frame capability slot. Conversion preserves the capability handle,
generation, rights, and derivation parent while changing the referenced object
type from `PhysicalFrame` to `MemoryObject`. A failed conversion leaves the frame
capability and physical authority intact.

The kernel retains immutable backing metadata for each memory object:

- physical start and byte size;
- normal-RAM attributes;
- the generation-checked physical-authority identity;
- the current number of published VMA mappings.

Normal RAM is zeroed through the architecture MMU interface before the converted
capability is exposed as a memory object. Mapping is eager and uses the exact
backing frame at `physical_start + object_offset`; it does not allocate object data
pages through the PMM or early allocator. Every mapping of the same object offset
therefore aliases the same physical frame.

Object mapping is transactional. The VMM installs page mappings into the explicit
address-space root before publishing VMA metadata or incrementing the object
mapping reference. If any page installation fails, all pages installed by that
request are unmapped and no mapping reference remains. Object-backed fault repair
may restore a missing PTE from immutable VMA backing metadata, but must never
allocate anonymous physical memory.

Explicit object destruction requires the `manage` right, rejects live mappings,
destroys the retained physical-frame authority, and invalidates the capability.
Revoking a physical-memory ancestor is stronger: descendant memory objects are
forcibly unmapped from every address space, destroyed deepest-first, and their
capability slots are invalidated before the authority range becomes reusable.

Anonymous VMAs are reservation-only metadata. They carry no implicit physical
allocation authority, and a not-present fault returns `MissingPhysicalBacking`.
Userspace must supply typed frame backing through a memory object before access can
succeed.

### Root-task userspace heap

The root task owns a bounded collection of page-aligned heap extents inside a
linker-defined virtual range. Every extent independently contains a boundary-tag
allocator; extents are not assumed to be physically or virtually contiguous.

Extent growth is transactional in this order: allocate a delegated physical
range, retype frames, create a memory object, map it, resolve the mapped address,
initialize allocator metadata, and only then publish the extent. Failure unwinds
in reverse order. If any kernel cleanup step fails, physical allocator ownership
is retained rather than advertised as free.

Allocation scans extents deterministically by virtual address and grows only after
all published extents report exhaustion. Empty non-initial extents may be reclaimed
through an explicit fallible operation. Partial cleanup progress is recorded so a
later retry cannot double-unmap or double-destroy. Reclaimed virtual holes are
eligible for deterministic reuse.

## Ownership and lifetime rules

1. Every mutable kernel object has one clearly identified owner of its internal
   state.
2. Capability possession grants authority; it does not by itself define object
   ownership.
3. Object identity is separate from capability-slot identity.
4. Deleting a capability removes an authority reference; it does not necessarily
   destroy the object.
5. Object destruction is permitted only when no required references, mappings,
   threads, waiters, or in-flight operations remain.
6. Destruction and multi-object creation must be transactional or return an
   explicit partial result that userspace can safely unwind.
7. Reused slots require stale-handle protection through generations or an
   equivalent mechanism.
8. Shared memory remains alive until the last valid object reference is released.
9. Fixed-capacity storage is acceptable initially, but exhaustion must be explicit
   and must not reach `unreachable` as ordinary runtime behavior.
10. Kernel faults and violated invariants remain fatal; user faults transition only
    the responsible execution context into a recorded faulted or exited state.

## Execution and concurrency model

The current kernel is intentionally single-CPU and mostly non-preemptive. Until
preemption or SMP is introduced:

- one current execution context is stored in clearly owned kernel state;
- object operations are serialized by the single executing CPU and interrupt
  masking rules;
- interrupt handlers must not allocate or invoke blocking policy;
- scheduler queues and object registries have one documented owner;
- no subsystem may assume that a global mutable pointer is safe after context
  switching is added.

Before timer preemption, SMP, or application-processor startup, the kernel must
define interrupt-save behavior, lock primitives, ownership boundaries, and a global
lock order. CPU-local current-thread state replaces the initial uniprocessor
accessor before multiple CPUs execute kernel code.

## First implementation slice

The first child-process milestone does not require every object above. The minimum
vertical slice is:

1. explicit current execution context;
2. safe checked user-memory copying;
3. contained user faults and non-halting child exit;
4. address-space objects with hardware roots;
5. one thread object and cooperative context switching;
6. real frame-backed memory objects funded by root-task authority;
7. root-task construction and execution of a child ELF.

IPC endpoints, notifications, capability transfer, timer preemption, and SMP remain
subsequent milestones unless implementation dependencies require an earlier subset.
