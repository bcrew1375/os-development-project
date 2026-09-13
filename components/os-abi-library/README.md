# OS Shared ABI and Library

This repository contains code shared across protection domains:

- `abi`: stable user/kernel ABI definitions such as boot information, syscall
  numbers, capability handles, and capability rights.
- `shared`: reusable implementation helpers that are safe for both kernel and
  userspace components, currently including ELF executable parsing.

The repository must not depend on kernel-private modules. Kernel and root-task
repositories should both depend on this package instead of copying ABI
definitions locally.

## Validation

```sh
zig fmt --check build.zig src tests
zig build tests
```

During early local development, sibling repositories may import modules from
this checkout by path. Once repository hosting and release packaging are in
place, consumers should switch to a pinned Zig package dependency.