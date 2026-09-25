test {
    _ = @import("kernel_common_tests.zig");
    _ = @import("vmm_tests.zig");
    _ = @import("process_tests.zig");
    _ = @import("thread_tests.zig");
    _ = @import("scheduler_tests.zig");
    _ = @import("lifecycle_tests.zig");
    _ = @import("capability_tests.zig");
    _ = @import("syscall_tests.zig");
    _ = @import("coverage_report_tests.zig");
    _ = @import("architecture_points_file_tests.zig");
    _ = @import("architecture_coverage_source_manifest_tests.zig");
    _ = @import("architecture_manifest_tests.zig");
    _ = @import("mock_architecture_tests.zig");
    _ = @import("early_allocator_tests.zig");
    _ = @import("physical_range_tests.zig");
    _ = @import("physical_memory_authority_tests.zig");
    _ = @import("interrupt_diagnostics_tests.zig");
    _ = @import("root_process_tests.zig");
    _ = @import("kernel_initialization_tests.zig");
    _ = @import("user_memory_tests.zig");
}
