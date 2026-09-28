comptime {
    _ = @import("syscall/dispatcher_tests.zig");
    _ = @import("syscall/memory_operation_tests.zig");
    _ = @import("syscall/error_mapping_tests.zig");
    _ = @import("syscall/production_memory_tests.zig");
    _ = @import("syscall/production_process_tests.zig");
    _ = @import("syscall/production_fault_tests.zig");
}
