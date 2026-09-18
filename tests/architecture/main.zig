const expected_fault = @import("expected_fault.zig");
const runner = @import("runner.zig");
const transport = @import("transport.zig");

const std = @import("std");

pub const panic = runner.panic;

pub fn architectureTestObserveException(
    vector: usize,
    error_code: usize,
    instruction_pointer: usize,
    cr2: usize,
) bool {
    return expected_fault.observe(vector, error_code, instruction_pointer, cr2);
}

pub export fn kernelMain() void {
    const summary = runner.run();
    transport.exit(if (summary.failed == 0) .success else .failure);
}

comptime {
    _ = std;
}
