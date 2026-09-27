# Current Kernel Assessment

Date: 2026-09-27

This document records a high-level assessment of the current repository state.
It is the single source of truth for implementation maturity, current risks, and
the priority-ordered technical backlog. Evergreen project conventions remain in
the [kernel code-organization reference](../reference/kernel-code-organization.md)
and [Zig code-structure reference](../reference/zig-code-structure.md).

## Executive summary

The project has progressed beyond a kernel bring-up scaffold into a small,
working capability-oriented microkernel prototype for x86-32 and x86-64. It now
demonstrates the complete path from boot to multiple isolated userspace
protection domains, including userspace-owned physical-memory policy, cooperative
thread scheduling, blocking IPC, capability transfer, managed lifecycle and fault
delivery, timer notifications, and an independently built restartable echo
service.

The strongest architectural result is the division of responsibility:

- the kernel owns protected objects, capability authorization, address-space and
  thread mechanisms, scheduling, IPC, interrupt delivery, and fault containment;
- the root task owns physical allocation, heap policy, ELF loading, child-process
  construction, cleanup, and service orchestration;
- the shared ABI, root task, and echo service are artifact and source boundaries,
  not kernel-private libraries linked into userspace;
- architecture-independent policy is exercised through a parity-checked mock,
  while real x86 mechanisms are tested under QEMU.

The project should still be described as an **early microkernel prototype**, not
a production-ready or seL4-equivalent system. It is single-core, cooperatively
scheduled, fixed-capacity, and tied to legacy x86 interrupt hardware. It has no
ACPI/APIC platform discovery, timer preemption, locking model, general service or
executable-discovery infrastructure, persistent process-management API, device
memory model, or formal verification. Several security-critical paths remain
panic-based when kernel invariants fail, and the architecture-dependent coverage
reports show substantial unexercised code.

The most accurate maturity description is:

> A functioning, well-tested capability-oriented x86 microkernel prototype with
> real userspace process construction and service isolation, but not yet a
> scalable, preemptive, hardware-general, or production-assured microkernel.

## Assessment basis

This assessment is based on direct source and build inspection plus a clean local
validation run on 2026-09-27 with Zig 0.16.0 and QEMU 8.2.2.

### Verified validation matrix

| Validation | Result |
| --- | --- |
| `zig fmt --check ...` | Passed for root build/source/test/tool trees and all three components |
| `zig build tests` | Passed; root Zig suite reported 207/207, and Python tooling suites reported 2, 34, and 17 passing tests |
| Echo-service component tests | Passed; 3/3 |
| `zig build coverage` | Passed; 1225/1225 emitted common-code lines, 100% |
| x86-32 production build | Passed |
| x86-64 production build | Passed |
| x86-32 physical architecture suite | Passed; 29 cases, including 6 expected-fault cases |
| x86-64 physical architecture suite | Passed; 32 cases, including 7 expected-fault cases |
| x86-32 architecture coverage | Passed; 191/395 emitted lines, 48.35% |
| x86-64 architecture coverage | Passed; 457/1060 emitted lines, 43.11% |
| x86-32 Limine production smoke | Passed; protocol 9 completed with status zero |
| x86-32 Multiboot production smoke | Passed; protocol 9 completed with status zero |
| x86-64 Limine production smoke | Passed; protocol 9 completed with status zero |
| `zig build docs` | Passed |

Coverage percentages describe emitted locations in the dedicated instrumented
binaries, not all source text. Common-code coverage is unusually strong, but it
does not substitute for physical execution of interrupt entry, context switching,
page tables, or boot code.

### Production behavior demonstrated end to end

The protocol-9 smoke path proves, on all three supported production boot paths:

1. kernel initialization and root-task ELF loading;
2. ring-3 entry through a normal scheduler-owned root thread;
3. validated boot modules and delegated physical-memory authority;
4. root-task physical allocation and capability-backed heap mapping;
5. cooperative yielding and scheduler resumption;
6. blocking three-word endpoint request/reply IPC;
7. exact-slot capability transfer with rights attenuation;
8. contained child exit and invalid-opcode fault;
9. parent/process-manager startup, lifecycle, and managed-fault messages;
10. timer interrupt delivery through a capability-authorized notification;
11. launch, request/reply, destruction, and restart of an independent echo service;
12. clean root-task exit without using a production `isa-debug-exit` hook.

This is meaningful system behavior, not metadata-only scaffolding.

## Current strengths

### Protection boundaries are real repository and artifact boundaries

The monorepo contains four independently scoped deliverables:

- the privileged kernel under `src`;
- `components/os-abi-library` for cross-domain ABI definitions and shared ELF
  parsing;
- `components/os-root-task` for initial userspace policy and child construction;
- `components/os-echo-service` for the first extracted userspace service.

The kernel consumes userspace programs as ELF boot artifacts. The root task and
echo service import the ABI rather than kernel-private implementation modules.
This is the correct direction for a microkernel project and makes future
repository extraction practical.

### The object model now supports useful isolated processes

The kernel has bounded, generation-checked objects for capability spaces,
address spaces, memory objects, physical-memory authority, threads, endpoints,
notifications, and logical interrupt sources. Address spaces own hardware roots;
memory objects own immutable delegated backing; threads own architecture contexts;
and capability spaces use local handles with rights checks and stale-handle
protection.

The root task constructs children through public syscalls rather than a privileged
kernel process-creation bundle. Construction and cleanup are transactional enough
to be retried safely, and child capability spaces begin empty unless authority is
explicitly installed or transferred.

### Memory policy is correctly outside the kernel

The kernel normalizes and excludes unsafe physical ranges, then delegates bounded
normal-RAM authority. The root task performs first-fit physical allocation,
retyping, memory-object creation, mapping, heap growth, and reclamation policy.
Production kernel code no longer exposes the abandoned general-purpose PMM or
kernel heap.

This boundary is one of the project's clearest design successes: page-table and
mapping enforcement remain privileged, while ordinary allocation policy is not
added to the trusted core.

### Common policy and physical mechanisms are separately verifiable

The architecture interface is compile-time checked across mock, x86-32, and
x86-64 implementations. Common capability, IPC, scheduler, lifecycle, memory,
syscall, and user-copy code is host tested and currently reports complete emitted
line coverage. Physical QEMU suites independently test page tables, exceptions,
privilege checks, boot modules, timers, syscall gates, context switching, and
deferred syscall writeback.

### The build and test infrastructure is unusually mature for the kernel stage

The build is decomposed by concern, supports both Limine targets plus x86-32
Multiboot, accepts an external root-task artifact, produces API documentation,
and has deterministic serial protocols for physical and production tests. CI uses
Zig 0.16.0 and exercises native checks plus both architecture builds, physical
suites, and production smoke paths.

## Current limitations and risks

### 1. Scheduling and concurrency remain prototype-level

The scheduler is a fixed-capacity cooperative FIFO on one CPU. A timer can wake a
notification waiter from the idle continuation, but it does not preempt an
ordinary running userspace thread. There are no priorities, time slices, CPU-local
current-thread state, kernel locks, lock ordering, or SMP startup model.

A user thread that never yields or blocks can monopolize the CPU. Introducing
preemption without first defining interrupt-save and object-locking rules would
make the current global registries unsafe.

### 2. Interrupt and platform support is still legacy x86-specific

The implementation uses the legacy PIC and PIT. There is no ACPI table discovery,
MADT parsing, Local APIC, I/O APIC, MSI/MSI-X routing, or interrupt-controller
abstraction broad enough for modern hardware. Only the timer is exposed as a
logical userspace interrupt source.

The x86-32 and x86-64 interrupt dispatchers also retain substantial duplicated
policy and panic-based invariant handling. Dedicated emergency exception stacks
are not yet part of the documented production model.

### 3. The userspace service environment is deliberately narrow

The echo service proves isolation and ABI-only IPC, but service discovery is fixed
policy in the root task. Executables must be packaged as boot modules. There is no
filesystem or executable-store service, service registry, naming, standard
arguments/environment contract, dynamic linker, shared-library mechanism, or
persistent client/service protocol.

IPC payloads are three fixed words. Capability transfer is a single-capability,
exact-slot rendezvous. Those constraints are suitable for proving mechanisms but
not for a general userspace ecosystem.

### 4. Resource capacity and lifetime policy do not yet scale

Kernel object storage is intentionally fixed: 16 capability spaces, 16 address
spaces, 32 threads, 32 endpoints, 32 notifications, 64 memory objects, and 128
physical-authority objects, among other bounded pools. Exhaustion is explicit,
which is good, but there is not yet a capability-funded kernel-object storage
model.

Capability derivation and deletion support the current delegation paths, but
broader revocation semantics, multi-level capability addressing, device-memory
retyping, cache attributes, and long-lived shared-resource policy remain limited.
Lower-level page tables are reclaimed with address-space destruction rather than
eagerly whenever tables become empty.

### 5. Fault and lifecycle reporting is useful but not general

User faults are attributed and contained, and managed fault messages can reach the
process manager. The current production examples use coarse terminal fault classes
and controlled reply behavior. There is no general pager protocol, demand paging,
copy-on-write, resumable exception framework, process wait API, persistent event
queue, or process namespace.

The root task is represented by the normal thread and scheduler machinery after
bootstrap, but its construction remains a privileged one-time kernel path rather
than a userspace-created process.

### 6. Assurance is good for a hobby prototype, not production-grade

The project has strong deterministic testing, but it has no formal specification,
proof, fuzzing campaign for protection-boundary state machines, static race model,
or security audit. Common emitted-line coverage is 100%, while physical emitted
coverage is only 48.35% on x86-32 and 43.11% on x86-64. In particular, interrupt,
boot, and console paths contain large unexecuted regions in the coverage kernels.

Panic-on-invariant-failure behavior is appropriate for broken kernel state, but
its frequency in architecture interrupt and context code increases the importance
of expanding adversarial physical tests before adding preemption.

### 7. Verification orchestration has two concrete maintenance gaps

The root `zig build tests` aggregate invokes the ABI and root-task component tests,
but does not invoke `components/os-echo-service` tests. The root formatting command
in CI likewise omits that component. Production smoke builds and runs the service,
and its independent 3-test suite passes, but the aggregate validation contract
should include every independently scoped component.

The weekly `test-trends.yml` workflow still requests Zig 0.15.2, while normal CI,
the devcontainer, and this verified assessment use Zig 0.16.0. Trend data is less
trustworthy if it is collected with a different compiler version.

### 8. Several large modules are becoming maintainability hotspots

`src/common/syscall/main.zig`, `src/common/capability/main.zig`, the root-task test
suite, and some architecture context/interrupt modules are large and carry many
responsibilities. The subsystem directories are sound, but continued feature work
should split decoding, object-specific syscall operations, registry mechanics, and
policy helpers before those files become monolithic coordination points.

## Prioritized next work

Priorities describe implementation order, not only severity.

### Priority 0: keep the verified baseline trustworthy

1. Add the echo-service component to the root aggregate test step and CI formatting
   check.
2. Align the trend workflow with Zig 0.16.0 and include echo-service test counts.
3. Keep all three production smoke paths green when ABI or boot packaging changes.
4. Add a concise checked validation script or build step that represents the full
   release-candidate matrix without relying on tribal knowledge.
5. Continue treating common coverage as diagnostic and prevent percentage goals
   from creating production test hooks.

**Done when:** One documented aggregate validation path checks every component,
both architectures, and every supported production boot path with one compiler
version.

### Priority 1: define and implement safe timer preemption

1. Document interrupt-save rules, mutable-state ownership, and lock ordering before
   enabling preemption.
2. Introduce a minimal spinlock/interrupt guard abstraction and CPU-local execution
   context even while only one CPU is active.
3. Add scheduler time accounting and a timer-driven reschedule request.
4. Preserve retained syscall continuation and notification wakeup semantics across
   involuntary switches.
5. Add starvation, repeated preemption, blocked-thread, fault-during-preemption, and
   kernel-critical-section tests on both x86 targets.
6. Add priorities only after basic preemption is correct; document inversion policy
   before capability-authorized services depend on priorities.

**Done when:** A non-yielding userspace thread cannot monopolize the CPU, and both
architectures repeatedly preempt and resume isolated threads without corrupting
kernel object state.

### Priority 2: replace legacy interrupt plumbing with a controller boundary

1. Define an interrupt-controller interface independent of PIC and APIC details.
2. Move common vector classification, acknowledgement, masking, and source binding
   behind that interface.
3. Add ACPI RSDP/XSDT/RSDT and MADT discovery with adversarial parser tests.
4. Implement Local APIC timer and I/O APIC routing while retaining PIC as a tested
   fallback.
5. Extend logical interrupt-source capabilities beyond the timer and define device
   source ownership, masking, acknowledgement, and teardown.
6. Add dedicated emergency stacks for double fault and other non-recoverable entry
   paths where supported.

**Done when:** Supported QEMU machine configurations can boot and route tested
interrupt sources through APIC infrastructure without common policy importing PIC
modules directly.

### Priority 3: grow a real userspace service environment

1. Define a minimal service registry and discovery protocol in userspace.
2. Extract executable/boot-module lookup behind an executable-store service
   boundary.
3. Add a separate client ELF for the echo service and test client/service restart
   independently of root-task control flow.
4. Define standard startup arguments, environment, and capability bootstrap data.
5. Design larger payloads around shared memory or mapped buffers rather than
   expanding register IPC without bounds.
6. Add at least one device-facing service after interrupt-source authority is
   generalized.

**Done when:** A client discovers and uses a restartable service through userspace
policy, without the root task hard-coding the complete request path.

### Priority 4: improve scalable resource and memory semantics

1. Design capability-funded storage for kernel object metadata before fixed pools
   become operational limits.
2. Define broader capability revocation and descendant cleanup semantics.
3. Add device-memory authority with explicit cacheability and mapping attributes.
4. Complete empty page-table reclamation and document ownership of every page-table
   page.
5. Design pager, demand-fault, and copy-on-write protocols as userspace policy over
   explicit kernel mechanisms.
6. Preserve transactional creation and retryable destruction for every expanded
   multi-object operation.

**Done when:** Long-lived services can create, delegate, revoke, and reclaim
resources without relying on globally fixed object counts or ambiguous backing
lifetime.

### Priority 5: increase assurance at architecture boundaries

1. Target uncovered interrupt, boot, context, and MMU paths with physical tests
   based on risk, not percentage alone.
2. Add fuzz/property testing for ELF planning, capability derivation, IPC queue
   cancellation, process cleanup, physical-range normalization, and syscall
   argument decoding.
3. Add explicit hostile userspace scenarios for malformed pointers, repeated
   lifecycle races, stale capabilities, teardown with blocked waiters, and resource
   exhaustion.
4. Separate common interrupt policy from x86 entry mechanics to reduce duplicated
   proof and test burden.
5. Keep kernel-mode invariant failures fatal, but improve stage-specific diagnostics
   so failures identify the owning object and transition.

**Done when:** The highest-risk protection-boundary transitions have deterministic
negative tests on mock and physical implementations, and duplicated architecture
policy is materially reduced.

### Priority 6: prepare for SMP only after preemption is stable

1. Define per-CPU current-thread, idle-context, interrupt, and scheduler state.
2. Assign ownership or locking to every mutable registry and queue.
3. Define TLB shootdown, cross-CPU wakeup, capability mutation, and object teardown
   protocols.
4. Start application processors only after the lock and interrupt-controller models
   are exercised on one CPU.

**Done when:** The kernel can mechanically explain who owns every mutable field and
how cross-CPU operations preserve object and capability invariants.

### Priority 7: continue modularization and documentation discipline

1. Split the syscall dispatcher by object family while keeping one canonical ABI
   decode and result contract.
2. Split capability registry mechanics from object-specific capability operations.
3. Keep architecture-dependent code minimal and consolidate duplicated x86
   interrupt policy.
4. Update the current-state, object-model, flowchart, and assessment documents with
   every production-path or ownership change.
5. Keep completed roadmap records historical; do not let their original limitation
   text masquerade as the current baseline.

**Done when:** Major subsystem files retain one name-worthy responsibility and the
documentation clearly distinguishes completed history from current limitations.

## Recommended next vertical slice

The next vertical slice should be **safe timer preemption of two ordinary user
threads**, not another metadata object or kernel allocator:

1. document the uniprocessor lock and interrupt-save contract;
2. introduce CPU-local current execution state;
3. add a timer reschedule request without switching inside arbitrary object
   mutation;
4. preempt between two isolated threads with different address and capability
   spaces;
5. preserve blocked endpoint and notification behavior;
6. contain one child fault while the peer continues;
7. prove repeated preemption on x86-32 and x86-64 physical tests;
8. extend production smoke only after the mechanism passes dedicated physical
   stress tests.

This slice addresses the largest functional limitation visible to userspace while
forcing the concurrency rules needed for later APIC and SMP work.

## Bottom line

The kernel's current state is substantially stronger than its previous assessment
suggested. Threads, scheduling, backed memory objects, capability spaces, blocking
IPC, capability transfer, lifecycle delivery, notifications, and a split service
are implemented and demonstrated on both x86 targets. The project has crossed the
line from "microkernel-shaped bring-up" to a real early microkernel prototype.

Its next risk is no longer missing basic objects; it is scaling those mechanisms
without weakening their current clarity. Preemption, interrupt-controller
modernization, capability-funded resource growth, broader userspace services, and
stronger architecture assurance should now take precedence over adding unrelated
features.
