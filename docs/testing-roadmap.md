# Testing Roadmap

Status date: 2026-09-18

This document is the operational plan for improving test fidelity and expanding
what can be tested. The broader architectural priorities remain in
[`kernel_analysis.md`](../kernel_analysis.md). This roadmap tracks concrete
testing work, dependencies, acceptance criteria, and validation commands.

Coverage percentages are diagnostic. A higher percentage is not, by itself, a
reason to expose private production hooks or distort production code.

Physical-memory allocation and kernel-heap policy are excluded from this kernel
testing roadmap. Their current implementations and tests are experimental
fragments intended to move to a user-space memory-management component in the
seL4-style design. The kernel test root therefore does not import
`tests/pmm_tests.zig` or `tests/heap_tests.zig`. Mock physical-memory backing may
still be used to test kernel-owned MMU and virtual-address-space mechanisms.

## Status legend

- `[ ]` — not started
- `[~]` — in progress
- `[x]` — complete
- `[!]` — blocked; the item must name its blocker

When an item is completed, add its completion date, validation commands, and a
short note describing any deliberate limitation.

## Baseline

The baseline recorded on 2026-09-18 is:

| Suite | Baseline |
| --- | ---: |
| Native kernel Zig tests | 77 |
| Host Python tooling tests | 24 |
| ABI library tests | 10 |
| Root-task tests | 1 |
| x86-32 physical tests | 6 |
| x86-64 physical tests | 11 |
| Common emitted-line coverage | 90.59% |
| x86-32 emitted architecture coverage | 57.43% |
| x86-64 emitted architecture coverage | 59.72% |

These numbers are a comparison point, not fixed completion thresholds. Emitted
coverage includes only runtime locations present in the exact instrumented test
binary.

## Rules for all phases

1. Put tests under the appropriate `tests` directory, not in production source
   files.
2. Do not add test-only methods to production architecture interfaces.
3. Keep mock and physical architecture interfaces in parity.
4. Put additional observability in mock-owned test support or explicit state
   values.
5. Extract hardware-independent policy into pure helpers where practical.
6. Verify hardware mechanisms under QEMU rather than through production
   backdoors.
7. Give every test deterministic setup and reset behavior.
8. Never swallow test setup errors.
9. Treat coverage as a measurement, not as a reason to manufacture execution.
10. Record the relevant validation command when completing an item.

## Phase 1 — Make existing tests trustworthy

**Objective:** Remove false positives, eliminate hidden state leakage, make
mocks observable, and enforce existing physical tests in CI.

### [x] T1.1 Replace empty terminal tests with observable tests

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: Mock console state is bounded and records initialization, output bytes,
  and color transitions.

**Files:**

- `tests/kernel_common_tests.zig`
- `src/architecture/mock/platform/main.zig`

**Work:**

- capture console initialization;
- capture bytes written by the mock console;
- capture color changes;
- add deterministic reset support;
- replace comment-only terminal tests with assertions.

**Acceptance criteria:**

- no test body consists only of comments;
- terminal initialization is observable;
- default-color output is verified;
- colored output and restoration of the default color are verified.

**Validation:** `zig build tests`

### [x] T1.2 Make test setup failures explicit

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: VMM setup helpers now return errors and every invocation uses `try`.

**Files:**

- `tests/vmm_tests.zig`
- other test setup helpers that catch and ignore initialization errors

**Work:** Return errors from setup helpers and use `try` so failed setup stops
the test immediately.

**Acceptance criteria:**

- setup failures cannot be converted into a log message followed by continued
  execution;
- each affected test establishes its own prerequisites.

**Validation:** `zig build tests`

### [x] T1.3 Stabilize the mock memory lifecycle

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: The mock MMU owns one configurable backing allocation with explicit
  initialization, reset, and deinitialization.

**Files:**

- `src/architecture/mock/mmu/main.zig`
- `src/architecture/mock/early_allocator/main.zig`
- `src/architecture/early_allocator.zig`

**Work:**

- initialize one explicitly owned physical-memory backing region;
- make memory-map reads side-effect free;
- add deterministic reset and deinitialization;
- reset mappings, reservations, counters, and allocator transition state;
- support configurable memory-map fixtures.

**Acceptance criteria:**

- repeated memory-map reads do not allocate memory;
- repeated fixture initialization does not leak memory;
- memory tests do not depend on execution order;
- use before initialization is detected.

**Validation:** `zig build tests`

### [x] T1.4 Make architecture mocks observable

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: Mock-only state records boot, interrupt, console, timer, and CPU
  operations without changing the production architecture interface.

**Depends on:** T1.3 for shared reset conventions.

**Files:**

- `src/architecture/mock/boot/main.zig`
- `src/architecture/mock/interrupts/main.zig`
- `src/architecture/mock/platform/main.zig`
- `src/architecture/mock/cpu/main.zig`

**Work:**

- configure boot modules and observe boot finalization;
- record interrupt initialization, installed vectors, enabled state, and
  acknowledgements;
- record console and timer operations;
- define an isolated strategy for observing non-returning CPU operations;
- add reset and query support owned by the mock implementation.

**Acceptance criteria:** Architecture-independent tests can assert externally
visible effects without expanding production architecture interfaces.

**Validation:** `zig build tests`

### [x] T1.5 Validate the normal QEMU test protocol

- Completed: 2026-09-18
- Validation: `python3 -m unittest tests/architecture_coverage_tests.py`;
  `zig build architecture-tests -Darch=x86_32`;
  `zig build architecture-tests -Darch=x86_64`
- Notes: The runner rejects malformed, incomplete, duplicate, contradictory,
  out-of-order, and wrong-architecture protocol streams.

**Files:**

- `tools/architecture_test_runner.py`
- host tooling tests under `tests`

**Work:** Parse the versioned `QEMU-TEST` stream and validate:

- protocol version and architecture;
- declared and observed test counts;
- exactly one result for each started test;
- summary totals against individual records;
- successful QEMU exit against protocol success.

**Acceptance criteria:** Malformed, incomplete, duplicate, contradictory, or
wrong-architecture transcripts fail even when QEMU returns its success status.

**Validation:**

```sh
python3 -m unittest tests/architecture_coverage_tests.py
zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64
```

### [x] T1.6 Enforce physical validation in CI

- Completed: 2026-09-18
- Validation: `zig build tests`; both `architecture-tests`,
  `architecture-coverage-kernel`, and production build commands for x86_32 and
  x86_64; `git diff --check`
- Notes: Native validation runs once, while physical tests and build checks run
  in the architecture matrix with QEMU, xorriso, and Limine provisioned.

**File:** `.github/workflows/ci.yml`

**Work:**

- include Zig files under `tools` in formatting checks;
- run native/component tests once rather than once per architecture;
- run both physical architecture suites;
- build both architecture coverage kernels;
- retain production builds for both architectures.

**Acceptance criteria:** Pull requests cannot pass CI when either physical test
suite or either instrumented architecture kernel fails.

**Required CI commands:**

```sh
zig build tests
zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64
zig build architecture-coverage-kernel -Darch=x86_32
zig build architecture-coverage-kernel -Darch=x86_64
zig build -Darch=x86_32
zig build -Darch=x86_64
```

### Phase 1 exit gate

- [x] No empty or comment-only tests remain.
- [x] Setup failures fail immediately.
- [x] Memory and architecture mocks reset deterministically.
- [x] Mock side effects needed by common code are observable.
- [x] QEMU success requires a valid test protocol.
- [x] Both physical architecture suites run in CI.

## Phase 2 — Cover currently reachable behavior

**Objective:** Test behavior already reachable on the host without adding
production test hooks.

### [x] T2.1 Add direct early allocator tests

- Completed: 2026-09-18
- Validation: `zig build tests`; both architecture coverage commands.
- Notes: Invalid alignment, malformed or overlapping maps, arithmetic overflow,
  reservation exhaustion, later-region selection, reservation types, and ranges
  ending at the native address limit are covered. Firmware entries must be
  ordered and non-overlapping.

**Depends on:** T1.3.

**New file:** `tests/early_allocator_tests.zig`

**Coverage:**

- zero size and zero alignment;
- alignment handling;
- reserved-range skipping;
- selection of later available regions;
- out-of-space behavior;
- reservation-capacity exhaustion;
- reservation type preservation;
- malformed, overlapping, and unaligned memory-map entries.

**Validation:** `zig build tests`

### [x] T2.2 Complete VMM explicit-root and protection tests

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: Mock-only table/page failure injection is reset deterministically and
  supports root-specific inspection. Eager mapping and protection deliberately
  preserve partial progress and do not roll back earlier page operations.

**Depends on:** Mock MMU failure injection.

**File:** `tests/vmm_tests.zig`

**Coverage:**

- `mapEagerInAddressSpace`;
- `mapBootstrapContiguousInAddressSpace`;
- `protect` and `protectInAddressSpace`;
- isolation between address-space roots;
- missing-range protection;
- memory-object metadata;
- partial mapping and protection failures;
- documented rollback behavior;
- public fault-handler boundaries where safe on the host.

**Validation:** `zig build tests`

### [x] T2.3 Expand process ownership tests

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: Production owner-query APIs expose ownership without leaking registry
  slots. Address-space and memory-object capacities remain fixed and are tested
  through public creation paths.

**File:** `tests/process_tests.zig`

**Coverage:**

- owner-aware address-space and memory-object creation;
- owner preservation;
- object-range arithmetic overflow;
- supported permission combinations;
- VMM overlap propagation;
- deterministic table exhaustion.

**Validation:** `zig build tests`

### [x] T2.4 Resolve capability exhaustion semantics

- Completed: 2026-09-18
- Validation: `zig build tests`
- Notes: Removed unreachable `OutOfCapabilitySlots` from the public error set.
  Current capability creation exhausts its underlying object registry before the
  larger capability table; those propagated errors are tested. Independent
  capability derivation can introduce a reachable slot-exhaustion contract later.

**Files:**

- `src/common/capability/main.zig`
- `tests/capability_tests.zig`

**Decision:** Make capability-slot exhaustion reachable through capability
copy/derivation, reduce capacity to a reachable bound, or remove the premature
public error until independent capability creation exists.

**Acceptance criteria:** Every public capability error is reachable and tested,
or deliberately excluded with documented reasoning.

**Validation:** `zig build tests`

### [x] T2.5 Add comprehensive ELF parser fixtures

- Completed: 2026-09-18
- Validation: `cd components/os-abi-library && zig build tests`; `zig build tests`
- Notes: Generated in-memory ELF32 and ELF64 fixtures cover valid multi-segment
  images, permissions, malformed headers/tables, segment bounds, invalid indices,
  conversion and address arithmetic overflow, and invalid page sizes.

**Files:**

- `components/os-abi-library/tests/tests.zig`
- optional helpers under `components/os-abi-library/tests/fixtures`

**Coverage:**

- valid ELF32 and ELF64 images;
- multiple loadable segments, entry point, aggregate range, and permissions;
- unsupported class, endian, version, type, and machine;
- truncated or malformed program-header tables;
- invalid entry size;
- file size greater than memory size;
- segments outside the file, empty segments, and no loadable segments;
- arithmetic overflow and invalid segment indices.

**Validation:**

```sh
cd components/os-abi-library
zig build tests
```

### [x] T2.6 Test interrupt diagnostic policy

- Completed: 2026-09-18
- Validation: `zig build tests`; both production architecture builds.
- Notes: Diagnostic counters are explicit per-dispatcher state. Legacy PIC vector
  classification is a pure helper; hardware I/O remains covered only by physical
  architecture validation.

**Files:**

- `src/architecture/x86/common/interrupts/diagnostics.zig`
- `src/architecture/x86/common/interrupts/pic.zig`
- new `tests/interrupt_diagnostics_tests.zig`

**Preferred design:** Move diagnostic counters into an explicit state value. If
that is not yet practical, provide deterministic mock-owned reset support.

**Coverage:** Exception visibility, page-fault policy, timer sampling, one-time
hardware interrupt messages, out-of-range vectors, saturating counts, and pure
hardware-vector classification.

**Validation:** `zig build tests`

### [x] T2.7 Unit-test the architecture points-file parser

- Completed: 2026-09-18
- Validation: `python3 -m unittest tests/architecture_coverage_tests.py`;
  `zig build tests`; both `architecture-coverage` commands.
- Notes: Points format version 2 retains the runtime instrumentation count and
  adds a declared serialized source-point count, which the parser validates.

**Files:**

- `tools/architecture_coverage/points_file.zig`
- `tests/coverage_tests.zig` or a dedicated test file under `tests`

**Coverage:** Valid input, unsupported version, architecture mismatch, missing
headers, malformed records, invalid covered flags, invalid line numbers, extra
fields, and an empty point list.

**Validation:** `zig build tests`

### Phase 2 exit gate

- [x] Early allocator behavior has direct tests.
- [x] VMM public transitions have deterministic tests.
- [x] ELF validation branches have in-memory fixture coverage.
- [x] Pure interrupt policy is tested without hardware I/O.
- [x] Public but unreachable error contracts are resolved.

## Phase 3 — Make the active boot path testable

**Objective:** Test root-process preparation and root-task policy natively while
keeping non-returning hardware boundaries thin.

### [ ] T3.1 Add configurable boot modules to the mock

**File:** `src/architecture/mock/boot/main.zig`

**Work:** Configure zero or more modules backed by test bytes, expose whether
boot finalization occurred, and reset all state between tests.

**Acceptance criteria:** Tests can present valid and invalid boot-module ranges
without modifying production architecture interfaces.

**Validation:** `zig build tests`

### [ ] T3.2 Add deterministic direct-map backing

**Depends on:** T1.3.

**Files:**

- `src/architecture/mock/mmu/main.zig`
- `src/architecture/mock/early_allocator/main.zig`

**Work:** Back simulated physical memory with deterministic host storage,
translate the mock direct map into that storage, support explicit-root lookup,
and expose mapped contents and permissions through mock-owned queries.

**Acceptance criteria:** Native tests can inspect bytes written into a simulated
user address space.

**Validation:** `zig build tests`

### [ ] T3.3 Add root-process preparation tests

**Depends on:** T3.1, T3.2, and T2.5.

**Build files:**

- `build/modules.zig`
- `build/tests.zig`

**New file:** `tests/root_process_tests.zig`

**Production file under test:** `src/launch_root_process.zig`

**Coverage:**

1. missing and invalid modules;
2. malformed and minimal valid ELF images;
3. multiple loadable segments;
4. copied file bytes and zeroed BSS;
5. final segment permissions;
6. boot-information header and module truncation;
7. initial cdecl stack frame;
8. returned entry point and stack pointer;
9. missing explicit-root mappings.

Do not make `enterUserMode()` return for unit tests. Test preparation separately
and leave the non-returning transition to physical integration tests.

**Validation:** `zig build tests`

### [ ] T3.4 Inject a static userspace syscall transport

**Files:**

- `components/os-root-task/src/memory_manager.zig`
- `components/os-root-task/tests/tests.zig`
- a new root-task syscall transport helper if needed

**Design:** Use comptime/static polymorphism, not a runtime vtable.

**Coverage:** Syscall numbers, argument order, capability success and failure,
mapping results, permission flags, address-space creation, and memory-object
creation.

**Validation:**

```sh
cd components/os-root-task
zig build tests
```

### [ ] T3.5 Extract root-task startup policy from `_start`

**Depends on:** T3.4.

**Files:**

- `components/os-root-task/src/main.zig`
- a new root-task policy module if needed

**Work:** Keep `_start` as a thin freestanding boundary and move boot-info
validation and capability workflow into a function with statically injected
syscall, output, and exit behavior.

**Coverage:** Valid and invalid boot information, each capability/mapping
failure, successful completion, and diagnostic ordering.

**Validation:**

```sh
cd components/os-root-task
zig build tests
zig build -Darch=x86_32
zig build -Darch=x86_64
```

### [ ] T3.6 Add kernel initialization orchestration tests

**Related assessment:** P3.3 and P7.4 in `kernel_analysis.md`.

**Prerequisite:** Extract a staged, fallible initialization function from the
non-returning kernel entry point.

**Coverage:** Initialization order, terminal setup, boot finalization, interrupt
setup, and root-process preparation failure reporting.

**Acceptance criteria:** The hardware entry point remains thin, and common boot
policy can be tested with observable mocks.

**Validation:** `zig build tests`

### Phase 3 exit gate

- [ ] Root-process preparation has native tests.
- [ ] Userspace memory wrappers have transport-level tests.
- [ ] Root-task startup policy runs under component tests.
- [ ] Kernel initialization order can be asserted with mocks.
- [ ] Production non-returning boundaries retain their semantics.

## Phase 4 — Deepen physical architecture testing

**Objective:** Safely test destructive and hardware-sensitive behavior under
QEMU.

### [ ] T4.1 Add physical test execution modes

**Files:**

- `tests/architecture/framework.zig`
- `tests/architecture/registry.zig`
- `build/architecture_tests.zig`
- `tools/architecture_test_runner.py`

**Design:** Introduce named modes equivalent to:

```zig
pub const ExecutionMode = enum {
    shared_machine,
    isolated_machine,
    expected_fault,
};
```

**Acceptance criteria:** Nondestructive tests retain a fast shared kernel,
destructive tests receive separate QEMU instances, and expected faults have an
authoritative success protocol.

**Validation:**

```sh
zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64
```

### [ ] T4.2 Add physical MMU tests

**Depends on:** T4.1.

**Coverage:** Address-space root creation, explicit-root table and page mapping,
translation, root isolation, root switching, unmapping, permissions, and
allocator-exhaustion boundaries.

**Validation:** Both architecture test commands.

### [ ] T4.3 Add expected-fault tests

**Depends on:** T4.1.

**Coverage:** Unmapped access, write protection, user/supervisor violations,
non-executable mappings where supported, invalid opcode, and general-protection
faults.

**Acceptance criteria:** Each test validates the expected vector and available
fault metadata; reset, hang, or a different vector fails the test.

**Validation:** Both architecture test commands.

### [ ] T4.4 Observe real timer interrupts

**Depends on:** T4.1.

**Work:** Initialize the timer, enable interrupts, wait for bounded tick
progress, disable interrupts, and verify acknowledgement. Use timer-owned state
rather than parsing temporary diagnostic prose.

**Validation:** Architecture test command for each architecture that supports
the tested timer path.

### [ ] T4.5 Add boot-module fixture tests

**Work:** Package a deterministic fixture through Limine for x86-64 and add the
equivalent Multiboot module packaging for x86-32. Verify module count, range,
reservation, cache behavior, and capacity policy.

**Validation:** Both architecture test commands.

### [ ] T4.6 Extract and test common syscall dispatch

**Related assessment:** P0.3 in `kernel_analysis.md`.

**Files:**

- `src/architecture/x86/32/interrupts/main.zig`
- `src/architecture/x86/64/interrupts/main.zig`
- a new architecture-independent dispatch module and tests

**Work:** Separate trap-frame adaptation from syscall policy. Test policy with
plain native values and retain QEMU tests for interrupt-gate and register ABI
behavior.

**Validation:**

```sh
zig build tests
zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64
```

### Phase 4 exit gate

- [ ] Destructive tests run in isolated QEMU instances.
- [ ] Physical mapping and fault behavior are verified.
- [ ] Timer interrupts are observed rather than merely configured.
- [ ] Both boot-module adapters are exercised.
- [ ] Common syscall policy is natively testable and not duplicated by target.

## Phase 5 — Add full-system verification

**Objective:** Verify the production kernel, real root-task ELF, user-mode
entry, and syscall ABI as one system.

### [ ] T5.1 Add production system-smoke build steps

**Future commands:**

```sh
zig build system-smoke -Darch=x86_32
zig build system-smoke -Darch=x86_64
```

These commands do not exist yet; creating them is part of this item.

**Work:** Build and package the production kernel and root task, boot headlessly,
verify serial milestones and user-mode entry, exercise a capability-backed
workflow, and terminate QEMU authoritatively.

### [ ] T5.2 Define a versioned system-smoke protocol

**Depends on:** T5.1.

**Required records:** Kernel initialization stage, root-process preparation,
userspace entry, boot-information validation, capability acquisition,
memory-object mapping, and root-task exit.

**Acceptance criteria:** The host rejects missing, duplicate, malformed, and
out-of-order required records, as well as disagreement with QEMU exit status.

### [ ] T5.3 Add full-system jobs to CI

**Depends on:** T5.1 and T5.2.

**Required per pull request:** Formatting, native/component tests, production
builds, shared physical tests, architecture coverage-kernel builds, and system
smoke tests.

**Candidates for scheduled jobs:** Full coverage reports, isolated expected
faults, stress variants, and coverage trend publication.

### [ ] T5.4 Track test and coverage trends

**Track:** Native and component test counts, physical test counts, emitted
common coverage, emitted architecture coverage, and system-smoke status.

**Acceptance criteria:** Trends are visible, but coverage thresholds are not
used until denominators and suite responsibilities are stable.

### Phase 5 exit gate

- [ ] Both production architectures boot the real root task in CI.
- [ ] Userspace completes a capability-backed workflow.
- [ ] The system protocol and QEMU exit status agree.
- [ ] Failures identify the initialization stage that did not complete.
- [ ] Test and coverage trends are recorded without production test hooks.

## Validation matrix

Run the smallest command relevant to an item during development. Before closing
a phase, run every currently implemented command below:

```sh
zig fmt --check build.zig build docs/root.zig src tests tools \
  components/os-abi-library components/os-root-task

zig build tests
zig build coverage

zig build architecture-tests -Darch=x86_32
zig build architecture-tests -Darch=x86_64

zig build architecture-coverage-kernel -Darch=x86_32
zig build architecture-coverage-kernel -Darch=x86_64

zig build architecture-coverage -Darch=x86_32
zig build architecture-coverage -Darch=x86_64

zig build -Darch=x86_32
zig build -Darch=x86_64
```

Add the two `system-smoke` commands after T5.1 creates them.

## Updating this roadmap

When work starts, change its marker to `[~]`. When work is blocked, use `[!]`
and add a `Blocked by` line naming another roadmap item or an external issue.

Completed items should use this form:

```md
### [x] Tn.n Short work-item title

- Completed: 2026-09-18
- Validation: `<relevant validation command>`
- Notes: <important result or deliberate limitation>
```

Every completed item must satisfy these general requirements:

- implementation and tests are complete;
- affected documentation is current;
- formatting passes;
- relevant native, component, and architecture tests pass;
- no unrelated coverage-only production hooks were introduced.