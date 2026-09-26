# Root-Created Userspace Processes

Status date: 2026-09-25

The kernel supports meaningful root-created userspace processes, within a
deliberately limited execution model. A child is a real isolated protection
domain: the root task can load a native ELF executable into a separate address
space, bind it to a separate capability space and thread, run it through the
normal scheduler, contain its faults, and reclaim its resources.

This is enough for freestanding compute processes that use the current syscall
ABI. It is not yet a general-purpose application or service environment because
there is no IPC, filesystem-backed program service, standard argument and
environment convention, or preemptive scheduling.

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

The child capability space starts empty. The root task has a separate operation
for installing an attenuated capability into a managed capability space, but the
current child-construction path does not install any initial grants. A newly
started child therefore has no delegated memory-management, thread-management,
device, or service authority.

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

## Clean exit and fault containment

A clean child `exit` transitions only that thread to the exited state and records
its status. The scheduler then selects another runnable thread, allowing the root
task to continue and destroy the child resources.

A user fault is attributed to the responsible execution context. The production
smoke child demonstrates this by executing the invalid-opcode instruction `ud2`.
The child thread becomes faulted, the kernel reports the attributed fault, and
the root task resumes. The fault does not terminate the root task or the kernel.

Containment currently ends at stopping and attributing the fault. There is no
userspace fault-delivery endpoint, exception-handler registration, automatic
restart policy, or general parent notification/wait interface.

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

Production system-smoke protocol version 3 runs two children sequentially:

1. The clean child starts, yields, resumes, and exits with status zero. The root
   resumes and destroys all child resources.
2. The fault child starts, yields, resumes, and executes `ud2`. The kernel
   contains and reports the invalid-opcode fault, after which the root resumes and
   destroys all child resources.

The complete production path has been validated on:

- x86-32 with Limine packaging;
- x86-32 with direct Multiboot packaging; and
- x86-64 with Limine packaging.

These runs use independently built root-task and child ELF artifacts, production
page tables and interrupt paths, the public syscall ABI, and the ordinary
scheduler. See [Production System Smoke Tests](../testing/system-smoke.md) for the
ordered protocol and validation commands.

## Current limitations

The current implementation should not be described as a complete general-purpose
process model. Its deliberate limitations include:

- child executables must already be present as delegated boot modules;
- there is no filesystem, program registry, or general executable loader service;
- only native-class static, freestanding ELF images are supported;
- dynamic linking, interpreters, relocations, and shared libraries are absent;
- the startup contract has no command-line arguments, environment, or auxiliary
  vector;
- the child starts without delegated capabilities or service connections;
- there are no IPC endpoints, notifications, messages, or IPC capability
  transfer;
- there is no process ID namespace, naming service, process table, general wait
  API, or persistent parent/child event model;
- construction creates one initial thread per child;
- scheduling is cooperative and single-CPU rather than timer-preemptive;
- the stack location and 64 KiB size are fixed;
- an ELF may contain at most eight loadable segments;
- page-aligned `PT_LOAD` ranges may not overlap; and
- faults are contained but cannot yet be delivered to a userspace supervisor.

These restrictions mean a child can perform isolated computation and exercise
the syscall ABI, but it cannot yet participate in a useful multi-service
microkernel system. IPC, practical capability delegation, service discovery,
richer startup data, and process-manager policy are the next boundaries between
the current vertical slice and general-purpose userspace.

## Production and test boundaries

Production child creation uses public root-task wrappers over the syscall ABI.
Syscall authorization obtains caller identity from the scheduler-selected current
thread, and the child runs with its configured address-space and capability-space
identities.

Some isolated tests retain compatibility helpers for constructing a synthetic
root execution context. Those helpers are test infrastructure only; production
startup and child execution do not depend on synthetic root identity or a
test-only scheduler path.