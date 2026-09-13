# Repository Layout

The project is a monorepo containing three independently scoped deliverables:

- `src` and `tests`: privileged kernel code, architecture implementations,
  kernel tests, and boot-image packaging.
- `components/os-abi-library`: stable user/kernel ABI definitions and shared
  helpers usable across protection domains.
- `components/os-root-task`: the initial userspace root task, built as an
  independent freestanding ELF executable.

The component directories are ordinary tracked source trees, so a clone
contains everything needed to build and test the project. Each component is
also repository-shaped: it owns its build definition, source, tests,
documentation, and license. See [Component Workflow](component-workflow.md)
for extraction and reintegration instructions.

## Dependency direction

```text
os-abi-library
  ^
  |
  +-- kernel
  |
  +-- os-root-task
```

The ABI library must not depend on kernel-private or root-task code. The root
task must not import kernel-private modules and communicates with the kernel
only through the ABI.

The kernel consumes the root task as an ELF runtime artifact. It does not
compile or link root-task source into the kernel. The root task remains
independently buildable even while root-level orchestration invokes its build.

## Validation

Run every component's unit tests from the repository root:

```sh
zig build tests
```

Build the kernel and root-task artifacts for either architecture:

```sh
zig build -Darch=x86_64
zig build -Darch=x86_32
```

Components can also be validated in isolation:

```sh
cd components/os-abi-library
zig build tests

cd ../os-root-task
zig build tests
zig build -Darch=x86_64
zig build -Darch=x86_32
```

The kernel can consume an explicitly supplied root-task artifact:

```sh
zig build -Darch=x86_64 \
  -Droot-task=/path/to/root_process.elf
```

## Ownership boundaries

- ABI definitions and cross-domain helpers belong in
  `components/os-abi-library`.
- Root-task policy and userspace mechanisms belong in
  `components/os-root-task`.
- Kernel mechanisms, architecture implementations, and privileged subsystems
  belong in `src`.
- Cross-boundary interaction uses the ABI or built artifacts, never relative
  source imports into another component's private implementation.