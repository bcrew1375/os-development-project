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
    runtime.writeFrame(transport.coverageWriter()) catch |err| {
        transport.writer().print("QEMU-TEST COVERAGE-FAIL error={s}\n", .{@errorName(err)}) catch {};
        transport.exit(.failure);
    };
    transport.exit(if (summary.failed == 0) .success else .failure);
}
