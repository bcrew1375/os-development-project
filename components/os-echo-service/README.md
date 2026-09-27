# OS Echo Service

This component contains the first split userspace service. It is built as an
independent freestanding ELF executable and consumed by the kernel build as a
boot module. The root task loads it through the normal Phase 4 child-construction
path and delegates only endpoint IPC authority.

The service must import only the stable ABI package. It must not import
kernel-private modules, root-task implementation modules, or shared loader code.

## Protocol

The service receives `ChildStartup` with mode `service_echo` and two
installed endpoint capabilities: a receive-only request endpoint and a
send-only reply endpoint. It then:

1. receives one three-word `ECHO_SERVICE_REQUEST` message on the request
   endpoint;
2. validates the message against the ABI constant; and
3. sends one `ECHO_SERVICE_REPLY` message on the reply endpoint.

Any validation or syscall failure exits with `EXIT_FAILURE`; success exits with
`EXIT_SUCCESS`. The service is stateless, so the root task can destroy and
restart it against the same endpoints without any shared-state cleanup.

## Validation

```sh
zig fmt --check build.zig src tests
zig build tests
zig build -Darch=x86_32
zig build -Darch=x86_64
```

The default build expects the ABI component at
`../os-abi-library/src/abi/main.zig`. An extracted checkout can override that
location without changing source code:

```sh
zig build tests -Dabi-path=/path/to/os-abi-library/src/abi/main.zig
zig build -Darch=x86_64 \
  -Dabi-path=/path/to/os-abi-library/src/abi/main.zig
```
