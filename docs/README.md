# Documentation

This index is the entry point for project documentation. Documents are grouped
by purpose so current facts, operating instructions, future plans, and external
research are not confused with one another.

## Start here

- [Current Kernel Structure and Rationale](architecture/current-state.md) — what
  the repository implements today, how the pieces interact, and why the present
  boundaries exist.
- [Repository Layout](development/repository-layout.md) — directory ownership,
  dependency direction, build products, and validation commands.
- [Current Kernel Assessment](roadmaps/kernel-assessment.md) — dated maturity
  assessment, risks, and priority-ordered technical critique.
- [Kernel Object Model](kernel-object-model.md) — current ownership, lifetime,
  authorization, and concurrency contract for kernel objects.

## Architecture

- [Current Kernel Structure and Rationale](architecture/current-state.md) — the
  canonical overview of the implemented system and its architectural intent.
- [Kernel Object Model](kernel-object-model.md) — the contract that must guide
  new threads, address spaces, memory objects, capability spaces, and IPC objects.

Architecture documents describe stable or currently implemented relationships.
Proposals that are not implemented belong in `roadmaps`, not here.

## Development

- [Repository Layout](development/repository-layout.md) — source and component
  ownership boundaries.
- [Component Extraction and Reintegration](development/component-workflow.md) —
  preserving the repository-shaped ABI and root-task components.

## Testing

- [Production System Smoke Tests](testing/system-smoke.md) — end-to-end production
  boot protocol and QEMU termination behavior.
- [Architecture Coverage](testing/architecture-coverage.md) — physical x86
  coverage pipeline and its interpretation.
- [Testing Roadmap](roadmaps/testing-roadmap.md) — completed and planned work for
  test fidelity and verification infrastructure.

Generated Zig API documentation is separate from these narrative documents:

```sh
zig build docs
zig build serve-docs
```

## Roadmaps and assessments

- [Current Kernel Assessment](roadmaps/kernel-assessment.md) — dated assessment
  and prioritized backlog.
- [Userspace Process Roadmap](roadmaps/userspace-process-roadmap.md) — phased path
  from one bootstrapped root task to multiple isolated processes.
- [Testing Roadmap](roadmaps/testing-roadmap.md) — verification milestones and
  their recorded validation.

Roadmaps describe intended work. A roadmap item does not imply that the named
object or behavior exists in production code.

## Reference material

- [Kernel Code Organization](reference/kernel-code-organization.md) — research
  and principles used to guide subsystem and ownership boundaries.
- [Zig Code Structure](reference/zig-code-structure.md) — research and conventions
  for files, functions, interfaces, and decomposition.

Reference documents explain influences and coding principles. They are not a
status report for the kernel.

## Component-local documentation

The independently scoped components retain documentation beside their code:

- [`components/os-abi-library/README.md`](../components/os-abi-library/README.md)
- [`components/os-root-task/README.md`](../components/os-root-task/README.md)

That placement is deliberate: each component can be extracted into its own
repository without reconstructing its build or usage documentation.

## Documentation maintenance rules

1. Update `architecture/current-state.md` when implemented subsystem boundaries
   or the active boot path change.
2. Update `kernel-object-model.md` before implementing or changing an object
   type, ownership rule, lifetime rule, or concurrency assumption.
3. Update `roadmaps/kernel-assessment.md` when maturity, risks, or priorities
   change; retain its explicit assessment date.
4. Update the relevant roadmap when future sequencing or acceptance criteria
   change.
5. Keep commands and protocol details beside the subsystem that owns them.
6. Describe experimental or metadata-only code explicitly; do not present names
   as proof of complete semantics.
7. Add new documents to this index and verify all relative links.
