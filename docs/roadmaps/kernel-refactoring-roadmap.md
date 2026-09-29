# Kernel Refactoring Roadmap

Date: 2026-09-28

This roadmap identifies the kernel areas that are currently hardest to follow and
sequences behavior-preserving refactors that improve ownership, dependency
direction, and reviewability. It complements the broader
[current kernel assessment](kernel-assessment.md); it does not propose new kernel
features or semantics.

The recommendations follow the project rules in the
[kernel code-organization reference](../reference/kernel-code-organization.md)
and [Zig code-structure reference](../reference/zig-code-structure.md): organize
by subsystem, keep architecture-independent policy separate from mechanisms,
preserve explicit ownership, and extract only boundaries with a clear domain
responsibility.

## Status legend

- `[ ]` — not started
- `[~]` — in progress
- `[x]` — complete
- `[!]` — blocked; the item must name its blocker

When a phase is completed, record its completion date, validation commands, and
any important result or deliberate limitation.

## Scope and method

The assessment used direct source inspection plus a repository scan of Zig,
Python, and C files. The scan recorded file length, function and test density,
large functions, imports, and markers such as `TODO`, `@panic`, and
`unreachable`. Candidate modules were then reviewed for mixed responsibilities,
public API shape, mutable-state ownership, architecture duplication, and test
coverage boundaries.

The measurements below are snapshots from 2026-09-28. Line and function counts
are navigation signals, not quality thresholds. A smaller module can still be a
better refactoring target when it combines policy and mechanism, while a large
cohesive data structure may not need to be split.

## Evidence summary

### Common syscall dispatch

- **Measured evidence:** `src/common/syscall/main.zig` is 1,353 lines with 60
  functions and 11 imports. `dispatchWithServices` is 136 lines, and `errorCode`
  is 103 lines.
- **Mixed responsibilities:** ABI-number dispatch, argument conversion,
  object-specific authorization and policy, production userspace copying, error
  translation, and production service wiring.
- **Class:** API extraction.

### Capability subsystem

- **Measured evidence:** `src/common/capability/main.zig` is 822 lines with 60
  functions, 45 public functions, and 11 imports.
- **Mixed responsibilities:** table storage, handle validation, derivation-tree
  traversal, object creation and destruction, IPC forwarding, physical-memory
  authority, accounting, and test reset.
- **Class:** state-ownership cleanup and API extraction.

### x86 interrupt path

- **Measured evidence:** the x86-32 implementation is 328 lines, the x86-64
  implementation is 329 lines, and they have 93.8% line similarity. Both
  interrupt handlers are 89 lines.
- **Mixed responsibilities:** width-specific trap-frame access is interleaved
  with shared exception policy, IRQ routing, syscall-result policy, diagnostics,
  scheduling, and fault containment.
- **Class:** shared x86 policy extraction.

### x86 thread contexts

- **Measured evidence:** the x86-32 implementation is 439 lines, the x86-64
  implementation is 444 lines, and they have 84.3% line similarity.
- **Mixed responsibilities:** register-width and frame mechanics coexist with
  duplicated lifecycle and validation policy.
- **Class:** shared x86 policy extraction after interrupt work.

### Kernel root-process launch

- **Measured evidence:** `src/launch_root_process.zig` is 563 lines with 26
  functions. `prepareRootProcess` is 56 lines, and boot-module mapping is 69
  lines.
- **Mixed responsibilities:** transaction orchestration, ELF loading, user
  mappings, stack ABI, boot-info construction, physical-memory delegation, and
  rollback.
- **Class:** file split initially; API extraction only after transaction
  boundaries are explicit.

### Root-task startup

- **Measured evidence:** `components/os-root-task/src/startup.zig` is 510 lines,
  and `run` is 126 lines.
- **Mixed responsibilities:** boot validation, heap bootstrap, smoke-test policy,
  child and service orchestration, capability transfer, diagnostics, and
  environment adapters.
- **Class:** file split and test-infrastructure separation.

### Root-task child construction

- **Measured evidence:**
  `components/os-root-task/src/process_management/child_process.zig` is 491
  lines. Creation is 112 lines, and destruction is 83 lines.
- **Mixed responsibilities:** ELF planning, resource transaction, mapping
  ownership, cleanup, startup ABI encoding, and delegated-capability tracking.
- **Class:** state-ownership cleanup.

### Process registries

- **Measured evidence:** `src/common/process/main.zig` is 469 lines, and
  `src/common/process/thread.zig` is 474 lines.
- **Mixed responsibilities:** address-space and memory-object registries remain
  together; thread object state and bounded slot storage remain together.
- **Class:** deferred state-ownership cleanup.

### Root-task tests

- **Measured evidence:** `components/os-root-task/tests/tests.zig` is 1,749 lines
  with 41 tests.
- **Mixed responsibilities:** shared fake transports, memory fixtures, loader
  tests, allocator and heap tests, manager tests, and startup integration tests.
- **Class:** test-infrastructure separation.

### Syscall tests

- **Measured evidence:** `tests/syscall_tests.zig` is 1,290 lines with 15 tests
  and large recording and failing service implementations.
- **Mixed responsibilities:** dispatcher characterization, production
  integration, fake service contracts, and error mapping.
- **Class:** test-infrastructure separation.

### Capability tests

- **Measured evidence:** `tests/capability_tests.zig` is 784 lines with 25 tests.
- **Mixed responsibilities:** storage semantics, derivation and revocation,
  object lifecycle, authority, IPC capabilities, and capacity tests.
- **Class:** test-infrastructure separation.

Two findings drive the order of work:

1. The common syscall and capability files are the strongest readability
   hotspots because each is a public subsystem facade and also contains several
   unrelated implementation layers.
2. The x86 interrupt files have the clearest duplication signal, but changing
   them has a larger regression surface because they sit on exception, syscall,
   scheduling, and privilege-transition paths.

## Ranking by readability benefit

This rank describes expected maintainability benefit, not implementation order.

1. **Common syscall dispatch** — highest immediate benefit. Almost every kernel
   object operation passes through one dispatch file, and adding one syscall can
   require editing dispatch, decoding, error mapping, production adapters, and
   tests in distant regions of the same module.
2. **Capability storage and object operations** — high benefit and high design
   value. The current facade obscures which code owns slot state and which code
   invokes object-specific lifecycle policy.
3. **Shared x86 interrupt policy** — high benefit because two nearly identical
   implementations can drift, especially when preemption and locking rules are
   introduced.
4. **Root-process and root-task orchestration** — medium-to-high benefit. The
   transactional code is generally explicit, but bootstrapping, loading, smoke
   policy, and cleanup require long vertical navigation.
5. **Test infrastructure** — medium production-code benefit but very high
   enabling value. Smaller suites and reusable fakes make every later refactor
   easier to validate and review.
6. **Process registry storage** — medium benefit, deferred until capability work
   establishes the preferred bounded-storage pattern.

## Safe execution order

Each phase must remain independently reviewable and leave the full validated
baseline green. Do not combine these phases into one broad directory rewrite.

### [x] Phase 0: separate test infrastructure and lock down behavior

**Class:** test-infrastructure separation  
**Risk:** low  
**Dependencies:** none

**Completed:** 2026-09-28

- Root-task tests are split into subsystem-focused suites, with recording
  environments, transports, ELF builders, mapped-memory fixtures, diagnostic
  assertions, and boot fixtures under test support.
- Syscall tests are split into dispatcher, memory-operation, error-mapping, and
  production-adapter suites, with shared assertions, service fakes, and
  production fixtures under test support.
- Capability tests are split into storage, authority, installation, derivation,
  lifecycle, and memory-authority suites, with shared fixtures under test
  support.
- Physical x86 characterization covers immediate three-register syscall-result
  writeback through the real `int 0x80` gate on x86-32 and x86-64.
- Production notification characterization covers deferred interrupt-result
  writeback, source masking, successful acknowledgement rearming, and repeated
  acknowledgement error mapping.
- All 41 root-task, 15 syscall, and 25 capability legacy test names remain
  present without duplicates.

**Validation results:** `zig fmt --check components/os-root-task/tests tests`;
`zig build tests`; `zig build coverage` with 1,233 of 1,233 emitted common-code
lines covered; `zig build architecture-tests -Darch=x86_32`; `zig build
architecture-tests -Darch=x86_64`; relative roadmap-link validation; legacy
test-name comparison; `git diff --check`.

1. Split `components/os-root-task/tests/tests.zig` by subsystem: boot/bootstrap,
   physical allocator, heap, syscall managers, child loader, managed process,
   IPC/notification, and startup integration.
2. Move reusable recording transports, ELF builders, mapped-memory fixtures, and
   diagnostic assertions under `components/os-root-task/tests/support/`.
3. Split `tests/syscall_tests.zig` into dispatcher/object-family tests and
   production-adapter tests. Keep common request/result assertions and service
   fakes in `tests/support/syscall/`.
4. Split `tests/capability_tests.zig` by storage/handle semantics,
   derivation/revocation, memory authority, process objects, and IPC objects.
5. Add characterization cases before production moves where current behavior is
   implicit, especially syscall error mapping, capability rollback, interrupt
   result handling, and child-process cleanup order.

**Constraints:**

- Tests remain under `tests` directories; no tests move into source files.
- Production-only hooks must not be added to make splitting convenient.
- Shared test support must model the same compile-time service interfaces used by
  production, not introduce a second abstraction.

**Done when:** Each suite can be located by subsystem, test names and behavior are
unchanged, and coverage does not lose emitted common-code lines.

**Validation:** `zig fmt --check` on the affected trees; `zig build tests`;
`zig build coverage`; `git diff --check`.

### [x] Phase 1: decompose common syscall policy by object family

**Class:** API extraction  
**Risk:** medium  
**Dependencies:** Phase 0 syscall characterization

**Completed:** 2026-09-28

- `src/common/syscall/main.zig` remains the stable public facade for `Request`,
  `Operation`, `Failure`, `Result`, `dispatchFromCurrentContext`, and
  `dispatchWithServices`.
- Shared types and error mapping are isolated from memory, process, and IPC
  object-family policy without introducing runtime dispatch.
- Production capability, process, IPC, architecture-context, and checked
  userspace-copy adapters are confined to `production_services.zig`.
- The centralized syscall-number dispatcher is 71 lines and delegates typed
  policy to cohesive object-family modules.
- Object-family modules do not import architecture interrupt implementations,
  and architecture callers continue to consume the same result variants and
  register payloads.

**Validation results:** `zig fmt --check src/common/syscall`; `zig build tests`;
`zig build coverage` with 1,232 of 1,232 emitted common-code lines covered;
`zig build architecture-tests -Darch=x86_32`; `zig build architecture-tests
-Darch=x86_64`; `zig build -Darch=x86_32`; `zig build -Darch=x86_64`; `zig
build system-smoke -Darch=x86_32`; `zig build system-smoke -Darch=x86_64`;
`git diff --check`.

Keep `src/common/syscall/main.zig` as the stable public facade for `Request`,
`Operation`, `Failure`, `Result`, `dispatchFromCurrentContext`, and
`dispatchWithServices`. Move private implementation into cohesive modules under
`src/common/syscall/`:

- `dispatch.zig`: syscall-number switch only;
- `memory_operations.zig`: address spaces, memory objects, and physical-memory
  retype/delete/revoke requests;
- `process_operations.zig`: capability-space and thread lifecycle requests;
- `ipc_operations.zig`: endpoints, capability transfer, notifications, and
  interrupt-source requests;
- `error_mapping.zig`: operation selection and ABI error-code translation;
- `production_services.zig`: production adapters, including checked userspace
  request copies.

The dispatcher should retain centralized control flow. Object-family handlers
should decode typed request values, enforce the same rights, call the supplied
compile-time services, and return the existing `Result` union. Do not replace
static service injection with a runtime vtable.

**API rule:** Existing callers through `kernel_common.syscall` must not change.
Architecture interrupt code must continue to receive exactly the same result
variants and register payloads.

**Incremental sequence:**

1. Extract error mapping and conversion helpers without semantic changes.
2. Extract one object family at a time, starting with memory operations because
   their service and rights contracts are already strongly characterized.
3. Move production adapters only after all policy handlers are separate.
4. Reduce `main.zig` to the facade and dispatch entry points.

**Done when:** The public facade remains source-compatible, the syscall-number
switch is readable on one screen, object-family modules do not import
architecture interrupt implementations, and no error/result mapping changes.

**Validation:** `zig build tests`; `zig build coverage`; both architecture test
suites; both production builds; both production system-smoke tests;
`git diff --check`.

### [x] Phase 2: extract shared x86 interrupt and syscall-result policy

**Class:** shared x86 policy extraction  
**Risk:** high  
**Dependencies:** Phase 1 stable syscall facade and Phase 0 interrupt
characterization

**Completed:** 2026-09-29

`src/architecture/x86/common/interrupts/policy.zig` now owns the shared dispatcher,
including expected-fault interception, exception and page-fault routing, timer and
keyboard policy, PIC acknowledgement ordering, diagnostic state, syscall-result
handling, and scheduling-from-idle decisions. Width-specific `frame_adapter.zig`
modules retain trap-frame access, CR2 reads, register extraction, native-width test
observation values, and syscall-result writeback. Both adapters are checked against
the same compile-time contract, and each architecture's `interrupts/main.zig` is an
ABI-preserving 45-line hardware wrapper.

Physical characterization now includes containment of an unmapped user instruction
page fault on both widths, including the architecture-specific instruction-fetch
error bit. Architecture coverage inventory tests explicitly require the shared and
selected width-specific interrupt directories.

**Validation results:** `zig build tests`; `zig build coverage` with 1,233 of
1,233 emitted common-code lines covered; both architecture test suites; x86-32
architecture coverage at 191 of 402 coverable lines and x86-64 architecture
coverage at 457 of 1,102 coverable lines; x86-32 Limine and Multiboot production
builds; x86-64 production build; x86-32 Limine, x86-32 Multiboot, and x86-64
Limine system-smoke tests; `zig fmt --check` for changed Zig files; `git diff
--check`.

Create an x86-common policy module parameterized at compile time by a narrow
frame/mechanism implementation. Keep these width-specific:

- trap-frame layouts and interrupted-frame decoding;
- register extraction and syscall result writeback;
- CR2 and selector-width access;
- context-switch assembly and interrupt entry/return;
- IDT entry representation where width changes the hardware format.

Share these policies where behavior is identical:

- vector classification and exception routing;
- timer/keyboard IRQ routing and end-of-interrupt sequencing;
- user-fault classification and containment decisions;
- syscall dispatch result handling (`returned`, `blocked`, `yield`, debug write,
  exit, and failure);
- diagnostic throttling and panic policy for kernel faults;
- scheduling-from-idle decisions.

Prefer a compile-time implementation contract, consistent with
`makeArchitecture` and `validateImpl`, rather than runtime dispatch. Add
compile-time checks that both width-specific implementations provide the same
required frame operations.

Do not share code merely because text is similar. In particular, thread-context
storage should be addressed only after the interrupt policy boundary proves the
shape of the width-specific interface.

**Done when:** There is one source of truth for interrupt policy, x86-32 and
x86-64 files primarily expose hardware/frame mechanics, architecture facade
parity remains intact, and expected-fault tests still distinguish user
containment from kernel panic behavior.

**Validation:** both architecture test suites; both architecture coverage runs;
both production builds; x86-32 Limine, x86-32 Multiboot, and x86-64 Limine
system-smoke tests; `zig build tests`; `git diff --check`.

### [x] Phase 3: separate capability storage, derivation, and object adapters

**Class:** state-ownership cleanup and API extraction  
**Risk:** high  
**Dependencies:** Phase 0 capability characterization; preferably Phase 1 so
syscall callers depend only on the stable capability facade

**Completed:** 2026-09-29

`src/common/capability/main.zig` is now a 68-line compatibility facade with the
same 49 public declarations as before the split. `errors.zig` owns the shared
error set, `storage.zig` exclusively owns mutable capability slots and exposes
typed preparation, commit, rollback, resolution, replacement, clearing, counting,
reset, and bounded read-only scan operations. `derivation.zig` owns installation,
exact-slot transactions, generation-aware tree traversal, generic deletion, and
authorization cancellation. Memory, process, and IPC object lifecycle adapters
are separated into their planned object-family modules, and no internal capability
module imports the public facade.

Exact-slot rollback still restores the pre-commit slot without consuming a
generation. Backing objects remain unpublished until their prepared slot commits,
and traversal remains iterative, bounded, and allocation-free. Test reset clears
slots in place rather than materializing the full table array on the bounded
x86-32 kernel stack.

**Validation results:** `zig build tests`; `zig build coverage` with 1,260 of
1,260 emitted common-code lines covered, including every emitted line in the new
capability modules; both architecture test suites run serially with a 180-second
per-image timeout; x86-32 architecture coverage at 191 of 402 coverable lines and
x86-64 architecture coverage at 457 of 1,102 coverable lines; x86-32 Limine and
Multiboot production builds; x86-64 production build; x86-32 Limine, x86-32
Multiboot, and x86-64 Limine system-smoke tests; `zig fmt --check` for changed
capability files; public-symbol parity and exclusive slot-owner checks; `git diff
--check`.

Keep `src/common/capability/main.zig` as the public subsystem facade. Introduce
internal modules with one owner for mutable slot state:

- `storage.zig`: bounded tables, generation/retirement, slot allocation,
  lookup, clearing, counts, and reset;
- `derivation.zig`: parent references, descendant checks, leaf selection,
  install/commit/rollback, delete, and revoke traversal;
- `memory_capabilities.zig`: untyped memory, frames, memory objects, and address
  spaces;
- `process_capabilities.zig`: capability spaces and threads;
- `ipc_capabilities.zig`: endpoints, notifications, and interrupt sources.

The storage owner should expose typed operations rather than raw table pointers.
Object-family modules may request slot creation/resolution and lifecycle changes,
but must not own parallel capability tables. Derivation operations must remain
bounded and explicit; no heap allocation or recursive traversal should be added.

This phase should also make rollback ownership visible. Prepared installs and
object conversions need a single documented owner until commit, and cleanup
errors must retain current explicit handling.

**API rule:** Existing `kernel_common.capability` names and handle semantics stay
stable throughout the split. Avoid a new generic object interface unless more
than one real caller needs it; the closed `CapabilityObject` union remains a good
fit for the bounded object set.

**Done when:** Mutable capability slots have one identifiable owner, derivation
logic can be read without object-specific lifecycle code, object adapters cannot
bypass rights/type checks, and reset/count behavior remains deterministic.

**Validation:** `zig build tests`; `zig build coverage`; both architecture test
suites; both production builds and system-smoke tests; `git diff --check`.

### [x] Phase 4: clarify root-process and root-task transactions

**Class:** file split only first, followed by state-ownership cleanup  
**Risk:** medium to high  
**Dependencies:** Phases 0 and 3; capability ownership should be stable before
rewriting bootstrap transactions

**Completed:** 2026-09-29

`src/launch_root_process.zig` is now a 43-line facade with the same public surface
(`RootProcessLayout`, `PreparedRootProcess`, `prepareRootProcess`,
`enterPreparedRootProcess`, `isRootThreadForSmoke`). Its mechanics moved into
`src/root_process/`: `layout.zig` and `errors.zig` hold the shared virtual-address
map and error union, `user_memory.zig`, `executable_loading.zig`,
`initial_stack.zig`, `boot_modules.zig`, and `boot_info.zig` hold one mechanism
each, and `preparation.zig` owns `PreparedRootProcess`, `PreparationTransaction`,
and the ordered preparation flow. `PreparationTransaction` transitions the raw
address-space root into the registered capability and clears the superseded field,
so rollback destroys whichever form is currently owned and never releases the same
resource twice. A characterization test asserts the raw root is still reclaimed
when capability registration is the first step to fail.

The root task reduced `startup.zig` from 510 to 202 lines: `run` keeps its ordered
boot validation, allocator, address-space, and heap bootstrap sequence and the
cooperative-yield milestone, and now delegates every smoke scenario to the new
`smoke/` namespace. `components/os-root-task/src/smoke/main.zig` holds the
echo-service, notification, and child-process scenarios verbatim.
`child_process.zig` dropped from 491 to 281 lines, with load planning,
startup-ABI construction, and the unpublished-resource transaction extracted into
`load_plan.zig`, `startup_abi.zig`, and `Transaction.zig`.

The kernel-side split was verified as a pure move rather than by inspection alone:
every moved declaration was compared token-for-token against its pre-refactor text,
reporting zero missing, zero added, and zero differing declarations. The only
textual differences are optional trailing commas from re-wrapping long parameter
lists and call-site module qualification.

**Validation results:** `zig build tests`; root-task component tests in
`components/os-root-task`; `zig build coverage` with 1,261 of 1,261 emitted
common-code lines covered, including all 11 root-process tests; both architecture
test suites, each running 17 images with 0 failures (27 checks on x86-64, 25 on
x86-32); x86-64, x86-32 Limine, and x86-32 Multiboot production builds; all three
production system-smoke paths, each reporting `SYSTEM-SMOKE EXIT status=0` across
62 protocol milestones including echo-service request, verified reply, child
destruction, and service restart; `zig fmt --check`; `git diff --check`.

Deliberate limitations: non-root boot-module mappings are not tracked by
`PreparationTransaction`; they are released by `mapNonRootBootModules`'s own
`errdefer` while mapping, and any later failure reclaims them with the address-space
root that rollback destroys. `smoke/` remains production validation policy reachable
only when the environment declares the corresponding capabilities, so it is compiled
into the production root task rather than a test-only build.

For `src/launch_root_process.zig`, preserve `PreparedRootProcess` and the public
prepare/enter API while moving cohesive mechanics into:

- root ELF loading and segment-permission transitions;
- initial stack and call-frame construction;
- boot-info serialization and physical-memory delegation;
- non-root boot-module mapping;
- preparation rollback state.

For the root task:

1. Reduce `startup.run` to ordered initialization and top-level failure
   reporting.
2. Move smoke scenarios out of startup into a `smoke/` namespace. These are
   production validation policy, not heap/bootstrap mechanics.
3. Split `child_process.zig` into load planning, startup ABI construction, and a
   transaction type that exclusively owns unpublished resources.
4. Replace parallel Boolean ownership flags only when an explicit transaction
   state can make invalid cleanup order unrepresentable or assertable. Do not
   obscure cleanup in a generic framework.

**Boundary rule:** ELF parsing remains in the shared executable component;
kernel root-process loading and root-task child loading may share format helpers,
but must not share privileged mapping policy or ownership state.

**Done when:** Top-level startup and preparation functions read as ordered
control flow, each resource transaction has one owner, rollback order is local
to that owner, and smoke scenarios can be understood independently of bootstrap
mechanics.

**Validation:** root-task component tests; `zig build tests`; `zig build
coverage`; both production builds; all three production system-smoke paths;
`git diff --check`.

### [ ] Phase 5: evaluate process-registry and thread-context follow-ups

**Class:** state-ownership cleanup and possible shared x86 policy extraction  
**Risk:** medium to high  
**Dependencies:** Phases 2 and 3

After the earlier patterns are proven, reassess rather than automatically split:

- Separate address-space registry and memory-object registry storage from
  `src/common/process/main.zig` if each can own its state without circular
  dependency through mapping operations.
- Separate bounded thread slot storage from thread lifecycle policy if doing so
  clarifies scheduler ownership.
- Extract shared x86 thread-context lifecycle/validation policy only where the
  Phase 2 frame interface demonstrates true semantic parity.

This phase is intentionally conditional. File size alone is not sufficient
reason to create more interfaces.

## Dependency and ownership guardrails

Every phase must preserve these directions:

1. Shared ABI defines wire values and structures but owns no kernel policy.
2. Common kernel policy depends on the architecture facade, never on a concrete
   x86 width.
3. Architecture implementations satisfy the facade and may call common policy
   only at explicit interrupt/syscall boundaries.
4. Root-task code uses the userspace ABI and cannot import kernel-private
   capability, process, or memory registries.
5. Test support depends on public or intentionally internal test surfaces; it
   must not become a production dependency.

Additional constraints:

- Preserve compile-time polymorphism for syscall services and x86 mechanism
  adapters.
- Preserve fixed-capacity storage and deterministic iteration.
- Preserve explicit error unions and cleanup behavior.
- Keep facade files as navigable subsystem maps rather than compatibility bags.
- Do not move tests into source files.
- Do not mix feature work, preemption, APIC support, or ABI changes into these
  refactors.

## Review and validation protocol

Each pull request should perform one extraction step and record:

1. the old and new owner of every moved mutable field;
2. the public names intentionally preserved;
3. the compile-time dependency direction before and after;
4. characterization tests covering moved policy;
5. the narrow validation run used during development;
6. the full phase validation matrix before completion.

For documentation-only changes to this roadmap, validate relative Markdown links
and run `git diff --check`. For source refactors, use the phase-specific commands
above; architecture-boundary changes require both physical architecture suites
and all affected production smoke paths.

## Updating this roadmap

- Change `[ ]` to `[~]` when implementation begins.
- Use `[!]` only when a `Blocked by` line names another roadmap item or an
  external issue.
- Change a phase to `[x]` only after its done criteria are satisfied and its full
  validation matrix passes.
- Preserve completed phase records as historical evidence; update current
  limitations separately rather than rewriting completed results.

## Non-goals

This roadmap does not:

- change syscall numbers, capability handle encoding, or userspace ABI layouts;
- introduce dynamic allocation into kernel registries;
- add runtime vtables where compile-time interfaces already work;
- implement preemption, SMP, APIC support, or new process-management features;
- pursue target file lengths as an end in themselves;
- merge root-process and root-task loaders across their privilege boundary.

The desired result is not simply more files. It is a codebase in which policy,
mechanism, and mutable-state ownership are visible from directory structure and
facade APIs, while every intermediate change remains behaviorally proven.
