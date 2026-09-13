# Repository Layout

The project is split into three repositories:

- `os-development-project`: the kernel, architecture code, kernel subsystems, kernel tests,
  and boot-image packaging.
- `os-abi-library`: stable user/kernel ABI definitions and implementation helpers
  usable from both kernel and userspace.
- `os-root-task`: the initial userspace root task, built independently as a
  freestanding ELF executable.

## Dependency direction

```text
os-abi-library
  ^
  |
  +-- os-development-project
  |
  +-- os-root-task
```

The kernel consumes the root task as an ELF artifact. It must not compile the
root task from source.

## Submodule checkout

`os-abi-library` and `os-root-task` are tracked by the kernel repository as Git
submodules:

```text
/workspace/os-development-project
/workspace/os-development-project/dependencies/os-abi-library
/workspace/os-development-project/dependencies/os-root-task
```

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/bcrew1375/os-development-project.git
```

Initialize submodules in an existing checkout:

```sh
git submodule update --init --recursive
```

Update submodules to their configured remote branch tips when intentionally
advancing dependencies:

```sh
git submodule update --remote --merge
```

Build order:

```sh
cd /workspace/os-development-project/dependencies/os-abi-library
zig build tests

cd /workspace/os-development-project/dependencies/os-root-task
zig build -Darch=x86_64
zig build -Darch=x86_32

cd /workspace/os-development-project
zig build -Darch=x86_64
zig build -Darch=x86_32
```

The kernel build automatically builds the `os-root-task` submodule when
`-Droot-task` is not supplied, so a clean checkout can run `zig build` directly
after submodules are initialized.

The kernel can also consume an explicit root-task artifact path:

```sh
zig build -Darch=x86_64 \
  -Droot-task=/workspace/os-development-project/dependencies/os-root-task/zig-out/x86_64/bin/root_process.elf
```

## Future package-release step

The current integration uses direct paths to the submodule checkouts. Once
release tags exist and Zig package metadata is finalized, these direct paths can
be replaced with pinned Zig package dependencies.