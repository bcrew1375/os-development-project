const runner = @import("runner.zig");
const runtime = @import("architecture_coverage_runtime");
const transport = @import("transport.zig");

pub const panic = runner.panic;
pub const architecture_coverage = true;

comptime {
    _ = runtime;
}

pub export fn kernelMain() void {
    const summary = runner.run();
    runtime.writeFrame(transport.coverageWriter());
    transport.exit(if (summary.failed == 0) .success else .failure);
}
