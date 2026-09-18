const arch = @import("arch");
const framework = @import("framework.zig");
const registry = @import("registry.zig");
const transport = @import("transport.zig");

const std = @import("std");

pub fn run() framework.Summary {
    transport.initialize();
    return framework.runAll(
        transport.writer(),
        registry.architecture_name,
        registry.execution_mode,
        &registry.tests,
    );
}

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    arch.interrupts.disableInterrupts();
    transport.initialize();
    transport.writer().print("QEMU-TEST PANIC message=\"{s}\"\n", .{message}) catch {};
    _ = stack_trace;
    _ = return_address;
    transport.exit(.failure);
}
