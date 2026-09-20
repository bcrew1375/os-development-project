# Production System Smoke Tests

System smoke tests boot the packaged production kernel and independently built
root-task ELF under headless QEMU. Unlike architecture tests, they do not use a
test kernel, `isa-debug-exit`, or production test hooks.

## Commands

Run the default production packaging for each architecture:

```sh
zig build system-smoke -Darch=x86_32
zig build system-smoke -Darch=x86_64
```

x86-32 defaults to Limine and also supports the direct Multiboot packaging path:

```sh
zig build system-smoke -Darch=x86_32 -Dbootloader=multiboot
```

The default timeout is 60 seconds. Override it with
`-Dsystem-smoke-timeout=<seconds>`.

## Protocol

Production components unconditionally emit complete serial lines using protocol
version 1. The required order is:

```text
SYSTEM-SMOKE protocol=1
SYSTEM-SMOKE milestone=root_process_prepared
SYSTEM-SMOKE milestone=kernel_initialized
SYSTEM-SMOKE milestone=userspace_entered
SYSTEM-SMOKE milestone=boot_info_validated
SYSTEM-SMOKE milestone=address_space_capability_acquired
SYSTEM-SMOKE milestone=memory_object_capability_acquired
SYSTEM-SMOKE milestone=memory_object_mapped
SYSTEM-SMOKE EXIT status=0
```

The kernel emits the header after console initialization, records successful
root-process preparation, and records completion of boot finalization and
interrupt initialization. The root task records user-mode entry, valid boot
information, capability acquisition, and capability-backed memory-object
mapping. The kernel emits the terminal record only after accepting the root
task's exit syscall.

`tools/system_smoke_runner.py` ignores ordinary diagnostics but strictly rejects
missing, duplicate, malformed, unknown, or out-of-order protocol records. It
waits for a complete newline-terminated exit record, so partial serial writes
cannot be mistaken for completion. Failure output reports the last completed
stage and the protocol detail that prevented success.

## QEMU termination

The production guest intentionally halts after the root task exits. Once the
runner validates the terminal record, it negotiates QMP capabilities and sends
`quit`. A successful run therefore requires all of the following:

1. the complete ordered guest protocol;
2. guest exit status zero;
3. a successful QMP command exchange;
4. QEMU host process status zero after `quit`.

This keeps the production kernel independent of QEMU's `isa-debug-exit` device.
The serial transcript is retained as a Zig build output and printed on success
or failure.

## CI and trends

The architecture CI matrix runs the production smoke command for x86-32 and
x86-64 on every push and pull request. A weekly and manually dispatchable trend
workflow runs native coverage, both physical architecture suites, both
architecture coverage reports, and both production smoke tests. It uploads the
raw logs and a Markdown snapshot containing test counts, emitted-line coverage,
and smoke status for 90 days.

Trend reports are diagnostic. They do not enforce coverage thresholds while
coverage denominators and suite ownership remain subject to change.