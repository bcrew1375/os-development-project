const runner = @import("runner.zig");
const transport = @import("transport.zig");

const std = @import("std");

pub const panic = runner.panic;

pub export fn kernelMain() void {
    const summary = runner.run();
    transport.exit(if (summary.failed == 0) .success else .failure);
}

comptime {
    _ = std;
}
