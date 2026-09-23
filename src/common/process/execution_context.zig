//! Current execution identity for syscall and exception attribution.

const process = @import("main.zig");

pub const ThreadHandle = u32;
pub const CapabilitySpaceHandle = u32;

pub const ROOT_THREAD_HANDLE: ThreadHandle = 1;
pub const ROOT_CAPABILITY_SPACE_HANDLE: CapabilitySpaceHandle = 1;

pub const ExecutionContext = struct {
    thread_handle: ThreadHandle,
    capability_space_handle: CapabilitySpaceHandle,
    address_space_handle: process.AddressSpaceHandle,
    process_handle: process.ProcessHandle,
};

pub const ContextError = error{
    ExecutionContextAlreadyInitialized,
    ExecutionContextUninitialized,
};

var current_context: ?ExecutionContext = null;

pub fn initialize(context: ExecutionContext) ContextError!void {
    if (current_context != null) return ContextError.ExecutionContextAlreadyInitialized;
    current_context = context;
}

pub fn initializeRoot(address_space_handle: process.AddressSpaceHandle) ContextError!void {
    try initialize(.{
        .thread_handle = ROOT_THREAD_HANDLE,
        .capability_space_handle = ROOT_CAPABILITY_SPACE_HANDLE,
        .address_space_handle = address_space_handle,
        .process_handle = process.ROOT_PROCESS_HANDLE,
    });
}

pub fn current() error{ExecutionContextUninitialized}!ExecutionContext {
    return current_context orelse error.ExecutionContextUninitialized;
}

pub fn currentProcessHandle() error{ExecutionContextUninitialized}!process.ProcessHandle {
    return (try current()).process_handle;
}

pub fn currentAddressSpaceHandle() error{ExecutionContextUninitialized}!process.AddressSpaceHandle {
    return (try current()).address_space_handle;
}

pub fn replace(context: ExecutionContext) ContextError!void {
    if (current_context == null) return ContextError.ExecutionContextUninitialized;
    current_context = context;
}

pub fn resetForTest() void {
    current_context = null;
}
