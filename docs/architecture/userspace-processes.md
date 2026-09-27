# Root-Created Userspace Processes

Status date: 2026-09-27

The kernel supports meaningful root-created userspace processes, within a
deliberately limited execution model. A child is a real isolated protection
domain: the root task can load a native ELF executable into a separate address
space, bind it to a separate capability space and thread, run it through the
normal scheduler, contain its faults, and reclaim its resources.

This is enough for freestanding compute processes that use the current syscall
ABI and for a bounded manager/service handshake. It is not yet a general-purpose
application or service environment because
there is no filesystem-backed program service, general service registry,
standard argument and environment convention, or preemptive scheduling.

The broader ownership contract is documented in the [kernel object
model](../kernel-object-model.md). Planned extensions are tracked in the
[userspace process roadmap](../roadmaps/userspace-process-roadmap.md).

## Current process model

A process is currently a root-task policy record rather than a first-class
kernel `Process` object. The root task's `ChildProcess` record groups and owns:

- one capability-space capability;
- one address-space capability;
- one thread capability;
- one frame-backed memory object for every ELF segment;
- one frame-backed memory object for the initial stack; and
- the delegated physical-allocation handle funding every memory object.

The kernel independently tracks the thread's execution state, address space,
capability space, architecture context, exit status or fault state, and scheduler
membership. Kernel authority comes from capabilities, not from the userspace
`ChildProcess` record.

The child capability space starts empty. Construction may install only explicitly
selected startup capabilities. Managed children receive one parent-protocol
endpoint with attenuated send and receive rights. After the child announces
startup and requests a service, the root task transfers one send-only service
endpoint through IPC. No memory-management, thread-management, or device authority
is delegated by this path.

## Executable source and validation

The current root startup path obtains the child executable from a boot module
packaged with the system image. There is no filesystem or general executable
discovery service yet.

Before creating kernel objects, the root task parses and plans the complete ELF
image. The loader requires:

- an ELF class matching the running target: ELF32 on x86-32 or ELF64 on x86-64;
- no more than eight `PT_LOAD` segments;
- representable and non-overflowing virtual and memory ranges;
- at least one permission on every loadable segment;
- an entry point inside an executable loadable segment;
- no segment collision with the fixed initial-stack range; and
- no overlap between page-aligned loadable-segment mappings.

Page-aligned overlap is rejected even when the original ELF byte ranges do not
overlap. The current public mapping operation maps memory objects from offset
zero, so the loader cannot safely compose multiple segment views within a shared
page.

Only static, freestanding image loading is demonstrated. The root task does not
provide an interpreter, dynamic linker, shared-library resolver, or relocation
service.

## Protection-domain construction

After validation, construction proceeds transactionally:

1. Create a new, initially empty capability space.
2. Create an independently activatable address space with its own hardware root.
3. For each ELF segment, allocate page-aligned physical memory from the root
   task's delegated allocator.
4. Retype that physical range into frame authority and create a memory object.
5. Map the object into the child at the ELF virtual address with the segment's
   final read, write, and execute permissions.
6. Map the same object temporarily into the root task's reserved loader window
   with read/write permissions.
7. Copy the segment's file bytes through that alias. Memory beyond the file bytes
   remains zero initialized.
8. Construct a separate memory object for the initial stack and write the startup
   record into it.
9. Remove every root-task loader alias before making the child runnable.
10. Create and configure the child thread with its capability space, address
    space, entry point, stack pointer, and startup argument.
11. Start the thread as the final fallible construction operation.

The segment mappings retain their final ELF-derived permissions in the child.
The temporary writable aliases exist only in the root address space during image
construction and are removed before execution begins.

## Initial stack and startup ABI

Every child currently receives a fixed 64 KiB stack ending at virtual address
`0x00c00000`. The stack is backed by delegated physical frames, is mapped
read/write in the child, and is not executable.

The root writes a versioned 16-byte `ChildStartup` record near the top of the
stack. Version 1 contains:

- a magic value;
- an ABI version;
- a startup mode used by the current smoke child; and
- a reserved zero field.

The thread configuration supplies the startup-record address as the entry-point
argument. The architecture setup presents that argument according to the target
calling convention: as the first stack argument on x86-32 and in the first
integer argument register on x86-64. The loader also provides architecture-correct
stack alignment and a zero fake return address.

This fixed record proves that initialized data can cross from the root loader to
a new child. It is not a general `argc`/`argv`, environment, auxiliary-vector, or
process-bootstrap protocol.

## Execution and scheduling

The child thread enters through the same bounded FIFO cooperative scheduler used
by the root thread. It is not entered through a special test-only execution path.
The demonstrated child can:

- execute native user-mode code from its private address space;
- write diagnostics through `debug_write`;
- voluntarily yield the processor; and
- terminate itself through `exit`.

When a child yields, the scheduler selects the next ready thread. The root task
can consequently resume, yield again, and allow the child to continue. There is
no timer preemption: a runnable child that neither yields, exits, faults, nor
blocks in a future kernel mechanism can retain the processor indefinitely.

## Parent communication and terminal lifecycle delivery

The root task owns a `ManagedProcess` policy record for each managed child. It
groups the child resource owner with three separate endpoints:

- a parent-protocol endpoint used for startup, service request, and acknowledgment;
- a manager-only lifecycle endpoint bound to the child thread; and
- a service endpoint whose send-only capability is transferred after startup.

The parent and lifecycle endpoints are intentionally separate. The child can send
and receive protocol messages through its attenuated parent capability, but it
cannot forge or consume kernel lifecycle records. The lifecycle endpoint remains
manager-owned and cannot be destroyed while a configured thread references it.

The child startup record includes a manager-selected nonzero lifecycle token. The
kernel copies the resolved lifecycle endpoint identity and token into thread state
during checked thread configuration. On normal exit or a contained userspace
fault, common lifecycle policy generates exactly one three-word terminal record:

```text
event kind | lifecycle token | exit status or coarse fault reason
```

Kernel-originated delivery wakes a blocked receiver directly when one is waiting;
otherwise it queues the record on the endpoint. Architecture exception and syscall
handlers do not synthesize process-manager evidence. The root task emits smoke
records only after receiving and validating the kernel lifecycle message.

## Clean exit and fault containment

A clean child `exit` publishes the bound lifecycle record, transitions only that
thread to the exited state, and records its status. The scheduler then selects
another runnable thread, allowing the root task to receive the terminal event and
destroy the child resources.

A user fault is attributed to the responsible execution context. The production
smoke child demonstrates this by executing the invalid-opcode instruction `ud2`.
The child thread becomes faulted, the kernel publishes the configured coarse fault
record, and the root task resumes. The fault does not terminate the root task or
the kernel.

Managed faults may instead use U5.5 resumable fault IPC. The kernel retains the
user trap frame on the faulting thread's bounded kernel stack and sends four
three-word records containing the configured token, thread handle, reason, fault
address, instruction pointer, and architecture data. A manager holding the bound
endpoint's manage authority and the matching token may resume with the saved state,
replace only the instruction pointer, or terminate the thread. Missing or unusable
fault endpoints fall back to terminal containment; kernel-mode faults never route
through userspace.

## Capability-backed notifications and interrupt delivery

Notifications are distinct kernel objects rather than endpoint variants. Each has
a saturating `u32` pending count, a sticky overflow flag, and at most one blocked
waiter. A wait atomically consumes the complete count and overflow state; when no
state is pending, the syscall frame is retained and the thread blocks. Signaling is
bounded and allocation-free, either incrementing the count or completing the one
retained waiter directly.

Interrupt-source capabilities name kernel-created logical sources, not userspace-
supplied IRQs or vectors. The initial source kind is the PIT-backed timer, configured
with a nonzero frequency. Binding requires bind authority over both the source and
notification. An empty wait performs the initial arm, delivery masks the source,
and explicit acknowledge authority is required to rearm it. Unbinding and source
destruction leave the hardware source masked.

Common code knows only logical source kinds and mask/unmask operations. The x86
implementation owns PIC IRQ selection and EOI. Bounded per-thread kernel stacks
are 16 KiB on x86-32 and 32 KiB on x86-64; the x86-64 interrupt trampoline also
preserves the SysV 16-byte call alignment. A timer interrupt completes and
queues the waiter without preempting an ordinary running userspace thread. When the
reserved idle continuation is active, the handler sends EOI and then switches to
the waiter through the existing kernel-continuation context-switch path.

## Transactional ownership and cleanup

Construction publishes ownership incrementally and unwinds failures in reverse
order. If memory-object creation fails after physical frames have been retyped,
the derived physical-frame capability is deleted before the allocator allocation
is returned to the free set. This prevents allocator reuse while live kernel
authority still references the range.

Normal destruction releases resources in dependency order:

1. destroy the thread;
2. remove any remaining root loader aliases;
3. unmap child segment and stack mappings;
4. destroy their memory objects and retained frame authority;
5. return physical allocations to the root allocator;
6. destroy the address space; and
7. destroy the capability space.

The `ChildProcess` record marks each successful cleanup operation. If a later
operation fails, destruction reports the failure while retaining enough state for
a retry without double-unmapping, double-destroying, or double-freeing resources.

## Demonstrated production behavior

Production system-smoke protocol version 9 retains the existing IPC, capability
transfer, and fault-containment children, then runs two managed children:

1. A managed clean child announces startup, requests a service, receives a
   send-only service endpoint, acknowledges readiness through that endpoint, and
   exits with status zero. The root validates the kernel lifecycle event before
   emitting `CHILD_EXIT` and reclaiming all child and endpoint resources.
2. A managed fault child completes the same startup and service handshake, then
   executes `ud2`. The root validates the kernel's coarse invalid-opcode lifecycle
   event before emitting `CHILD_FAULT` and reclaiming the resources.
3. After all children are reclaimed, the root creates a notification and timer
   source, binds them, and blocks in `notification_wait`. A real PIT interrupt masks
   the source, completes the retained syscall, and wakes the root from idle. The
   root acknowledges and rearms the source, then unbinds and destroys both objects.
4. Finally the root loads the independent echo service from its own boot module.
   The service's capability space starts empty and receives exactly two
   attenuated capabilities: a receive-only request endpoint and a send-only reply
   endpoint. It serves one three-word request/reply exchange and exits cleanly.
   The root reclaims the process and repeats the full cycle against the same
   endpoints, proving the service can be restarted without halting the kernel.

The complete production path has been validated on:

- x86-32 with Limine packaging;
- x86-32 with direct Multiboot packaging; and
- x86-64 with Limine packaging.

These runs use independently built root-task, child, and echo-service ELF
artifacts, production page tables and interrupt paths, the public syscall ABI,
and the ordinary scheduler. See [Production System
Smoke Tests](../testing/system-smoke.md) for the ordered protocol and validation
commands.

## First service split

The echo service lives in the independent `components/os-echo-service`
component, outside the root-task tree. Its ownership boundary is:

- the service imports only the stable ABI package (`os-abi-library`); it must
  not import kernel-private modules, root-task implementation modules, or
  shared loader code;
- the root task is the client for the initial slice; it loads the service image
  through the same Phase 4 child-construction path used for every other child;
- delegated authority is exactly one receive-only request endpoint and one
  send-only reply endpoint. The service holds no memory-management,
  thread-management, interrupt, or lifecycle authority, which is strictly
  narrower than root-task authority; and
- the component carries its own linker scripts and build file so it can be
  extracted into a separate repository with only an ABI path override.

The request/reply protocol is a single fixed three-word message pair defined in
the ABI, so client and service communicate only through ABI-defined IPC. The
service is stateless, so a faulting or restarting instance cannot corrupt shared
state; the kernel and root task both survive service exit and restart.

## Current limitations

The current implementation should not be described as a complete general-purpose
process model. Its deliberate limitations include:

- child executables must already be present as delegated boot modules;
- there is no filesystem, program registry, or general executable loader service;
- only native-class static, freestanding ELF images are supported;
- dynamic linking, interpreters, relocations, and shared libraries are absent;
- the startup contract has no command-line arguments, environment, or auxiliary
  vector;
- service discovery is a fixed demonstration protocol rather than a registry;
- IPC payloads remain three fixed words and capability transfer is exact-slot,
  single-capability rendezvous;
- there is no process ID namespace, naming service, process table, general wait
  API, or persistent parent/child event model;
- construction creates one initial thread per child;
- scheduling is cooperative and single-CPU rather than timer-preemptive;
- the stack location and 64 KiB size are fixed;
- an ELF may contain at most eight loadable segments;
- page-aligned `PT_LOAD` ranges may not overlap; and
- lifecycle faults expose only a terminal coarse class and cannot be resumed.
- only the timer is exposed as a logical interrupt source, notifications permit one
  waiter, and interrupt delivery does not preempt an ordinary running thread.

These restrictions mean a child can perform isolated computation, communicate
with its manager, receive one attenuated service capability, and report terminal
lifecycle state, receive resumable managed faults, wait for an authorized timer
notification, and host one independent request/reply service in its own
protection domain, but it cannot yet participate in a general multi-service
microkernel environment. Richer startup data, broader interrupt routing, service
discovery, and broader policy remain future work.

## Production and test boundaries

Production child creation uses public root-task wrappers over the syscall ABI.
Syscall authorization obtains caller identity from the scheduler-selected current
thread, and the child runs with its configured address-space and capability-space
identities.

Some isolated tests retain compatibility helpers for constructing a synthetic
root execution context. Those helpers are test infrastructure only; production
startup and child execution do not depend on synthetic root identity or a
test-only scheduler path.