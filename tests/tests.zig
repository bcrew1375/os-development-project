// VMM mechanism tests currently traverse the experimental PMM implementation.
// Provide its kernel image bounds without importing the PMM policy test suite.
export const _kernel_start: usize = 0;
export const _kernel_end: usize = 1024 * 1024;

test {
    _ = @import("kernel_common_tests.zig");
    _ = @import("vmm_tests.zig");
    _ = @import("process_tests.zig");
    _ = @import("capability_tests.zig");
    _ = @import("coverage_tests.zig");
    _ = @import("mock_architecture_tests.zig");
    _ = @import("early_allocator_tests.zig");
    _ = @import("interrupt_diagnostics_tests.zig");
}
