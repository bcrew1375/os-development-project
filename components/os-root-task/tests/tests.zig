test {
    _ = @import("child_process_tests.zig");
    _ = @import("physical_allocator_tests.zig");
    _ = @import("heap_tests.zig");
    _ = @import("memory_manager_tests.zig");
    _ = @import("process_manager_tests.zig");
    _ = @import("ipc_tests.zig");
    _ = @import("notification_tests.zig");
    _ = @import("managed_process_tests.zig");
    _ = @import("bootstrap_tests.zig");
    _ = @import("startup_tests.zig");
}
