# OS Shared ABI and Library

This repository-shaped monorepo component contains code shared across
protection domains:

- `abi`: stable user/kernel ABI definitions such as boot information, syscall
  numbers, capability handles, and capability rights.
- `shared`: reusable implementation helpers that are safe for both kernel and
  userspace components, currently including ELF executable parsing.

The component must not depend on kernel-private or root-task modules. The
kernel and root task should both depend on this package instead of copying ABI
definitions locally.

## Validation

```sh
zig fmt --check build.zig src tests
zig build tests
```

The component intentionally retains its own build, tests, documentation, and
license so it can be extracted into an independent repository without
restructuring its source tree.