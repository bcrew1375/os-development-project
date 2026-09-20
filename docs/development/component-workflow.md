# Component Extraction and Reintegration

The directories under `components` are temporary monorepo homes for code that
may return to independent repositories. Their repository-shaped boundaries
must remain intact.

## Commit discipline

Prefer commits that modify one component or root-level integration, rather
than mixing unrelated kernel and component work. Path-scoped commits produce
clearer extracted histories and reviews. A necessary coordinated ABI change
may span consumers, but each component must remain buildable at the end of the
change.

Do not move component-owned source, tests, build definitions, linker scripts,
documentation, or licenses outside its component directory. Root-level build
logic may orchestrate a component but must not replace its standalone build.

## Extract a component

Create a branch whose repository root is the selected component:

```sh
git subtree split \
  --prefix=components/os-abi-library \
  --branch=extract/os-abi-library

git subtree split \
  --prefix=components/os-root-task \
  --branch=extract/os-root-task
```

Publish an extracted branch to an empty or compatible repository:

```sh
git push git@github.com:OWNER/os-abi-library.git \
  extract/os-abi-library:main

git push git@github.com:OWNER/os-root-task.git \
  extract/os-root-task:main
```

`git subtree split` retains component-relevant changes while excluding files
outside the selected prefix. Commit identifiers can be rewritten as part of
the prefix transformation, but authorship, messages, ordering, and component
content are retained.

After extracting the root task, either keep the ABI repository as a sibling
checkout or provide its entry point explicitly:

```sh
zig build tests \
  -Dabi-path=/path/to/os-abi-library/src/abi/main.zig
```

This path option is a development-time boundary. It can later be replaced by
pinned Zig package metadata without changing root-task source.

## Reintegrate independent development

If a component is developed independently and should temporarily rejoin the
monorepo, first ensure the target component directory is absent, then import
its full history without squashing:

```sh
git remote add os-abi-library URL
git fetch os-abi-library main
git subtree add \
  --prefix=components/os-abi-library \
  os-abi-library main
```

For an existing subtree that retains compatible subtree ancestry, pull new
component commits with:

```sh
git fetch os-abi-library main
git subtree pull \
  --prefix=components/os-abi-library \
  os-abi-library main
```

Do not use `--squash`: preserving component ancestry is more important than a
short root history for this project.

## Validate before extraction or reintegration

From the monorepo root, run:

```sh
zig fmt --check build.zig build docs/root.zig src tests \
  components/os-abi-library components/os-root-task
zig build tests
zig build -Darch=x86_32
zig build -Darch=x86_64
```

Then run the extracted component's standalone commands from its own root to
ensure no accidental monorepo dependency was introduced.