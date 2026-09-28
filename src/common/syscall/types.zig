//! Shared syscall request, diagnostic, and result types.

const arch = @import("arch");

/// Canonical syscall input after architecture register extraction.
pub const Request = struct {
    number: u32,
    arguments: [5]u64 = .{ 0, 0, 0, 0, 0 },
};

/// Kernel operation that failed while servicing a syscall.
pub const Operation = enum {
    resolve_execution_context,
    current_address_space,
    create_address_space,
    resolve_address_space,
    map_memory,
    create_memory_object,
    resolve_memory_object,
    map_memory_object,
    protect_address_space,
    query_address_space,
    unmap_address_space,
    destroy_address_space,
    retype_untyped_memory,
    delete_physical_memory,
    revoke_physical_memory,
    destroy_memory_object,
    create_capability_space,
    create_thread,
    configure_thread,
    start_thread,
    suspend_thread,
    resume_thread,
    terminate_thread,
    fault_reply,
    install_capability,
    destroy_thread,
    destroy_capability_space,
    delete_capability,
    create_endpoint,
    destroy_endpoint,
    endpoint_send,
    endpoint_receive,
    endpoint_send_capability,
    endpoint_receive_capability,
    create_notification,
    destroy_notification,
    notification_wait,
    notification_signal,
    create_interrupt_source,
    destroy_interrupt_source,
    bind_interrupt_source,
    unbind_interrupt_source,
    acknowledge_interrupt_source,
    convert_argument,
};

/// Failure information retained for architecture diagnostics and ABI writeback.
pub const Failure = struct {
    operation: Operation,
    err: anyerror,
    return_value: u32,
};

/// Result of common syscall policy before architecture-specific side effects.
pub const Result = union(enum) {
    returned: u32,
    returned_registers: arch.SyscallResultRegisters,
    blocked,
    yield,
    debug_write: struct {
        address: u64,
        length: u64,
    },
    exit: struct {
        status: u64,
    },
    failure: Failure,
};
