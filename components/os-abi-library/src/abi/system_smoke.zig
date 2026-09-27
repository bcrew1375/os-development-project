//! Versioned production lifecycle records consumed by full-system smoke tests.

const ipc = @import("ipc.zig");

pub const PROTOCOL_VERSION: u32 = 6;
pub const PREFIX = "SYSTEM-SMOKE";

pub const HEADER = PREFIX ++ " protocol=6\n";
pub const ROOT_PROCESS_PREPARED = PREFIX ++ " milestone=root_process_prepared\n";
pub const KERNEL_INITIALIZED = PREFIX ++ " milestone=kernel_initialized\n";
pub const USERSPACE_ENTERED = PREFIX ++ " milestone=userspace_entered\n";
pub const BOOT_INFO_VALIDATED = PREFIX ++ " milestone=boot_info_validated\n";
pub const BOOT_MODULES_VALIDATED = PREFIX ++ " milestone=boot_modules_validated\n";
pub const PHYSICAL_MEMORY_ALLOCATED = PREFIX ++ " milestone=physical_memory_allocated\n";
pub const ADDRESS_SPACE_CAPABILITY_ACQUIRED =
    PREFIX ++ " milestone=address_space_capability_acquired\n";
pub const MEMORY_OBJECT_CAPABILITY_ACQUIRED =
    PREFIX ++ " milestone=memory_object_capability_acquired\n";
pub const MEMORY_OBJECT_MAPPED = PREFIX ++ " milestone=memory_object_mapped\n";
pub const USERSPACE_HEAP_VERIFIED = PREFIX ++ " milestone=userspace_heap_verified\n";
pub const COOPERATIVE_YIELD_COMPLETED = PREFIX ++ " milestone=cooperative_yield_completed\n";
pub const IPC_REQUEST = ipc.Message{ .words = .{ 0x4950_4331, 0x1234_5678, 0xCAFE_BABE } };
pub const IPC_REPLY = ipc.Message{ .words = .{ 0x4950_4332, 0x8765_4321, 0xBEEF_CAFE } };
pub const IPC_CHILD_STARTED = PREFIX ++ " milestone=ipc_child_started\n";
pub const ROOT_RESUMED_AFTER_IPC_CHILD_BLOCKED =
    PREFIX ++ " milestone=root_resumed_after_ipc_child_blocked\n";
pub const IPC_REQUEST_SENT = PREFIX ++ " milestone=ipc_request_sent\n";
pub const IPC_REQUEST_VERIFIED = PREFIX ++ " milestone=ipc_request_verified\n";
pub const IPC_REPLY_SENT = PREFIX ++ " milestone=ipc_reply_sent\n";
pub const IPC_REPLY_VERIFIED = PREFIX ++ " milestone=ipc_reply_verified\n";
pub const CHILD_EXIT_FORMAT = PREFIX ++ " CHILD_EXIT status={d}\n";
pub const IPC_CHILD_DESTROYED = PREFIX ++ " milestone=ipc_child_destroyed\n";
pub const IPC_ENDPOINTS_DESTROYED = PREFIX ++ " milestone=ipc_endpoints_destroyed\n";
pub const CAPABILITY_TRANSFER_DESTINATION_SLOT: u32 = 7;
pub const CAPABILITY_TRANSFER_MESSAGE = ipc.Message{
    .words = .{ 0x4341_5031, 0x1357_9BDF, 0x2468_ACE0 },
};
pub const CAPABILITY_TRANSFER_ACK = ipc.Message{
    .words = .{ 0x4341_5032, 0, 0 },
};
pub const CAPABILITY_TRANSFER_CHILD_STARTED =
    PREFIX ++ " milestone=capability_transfer_child_started\n";
pub const ROOT_RESUMED_AFTER_TRANSFER_CHILD_BLOCKED =
    PREFIX ++ " milestone=root_resumed_after_transfer_child_blocked\n";
pub const CAPABILITY_TRANSFER_SENT = PREFIX ++ " milestone=capability_transfer_sent\n";
pub const CAPABILITY_TRANSFER_RECEIVED = PREFIX ++ " milestone=capability_transfer_received\n";
pub const CAPABILITY_TRANSFER_RIGHTS_ATTENUATED =
    PREFIX ++ " milestone=capability_transfer_rights_attenuated\n";
pub const CAPABILITY_TRANSFER_ACK_SENT = PREFIX ++ " milestone=capability_transfer_ack_sent\n";
pub const CAPABILITY_TRANSFER_ACK_VERIFIED =
    PREFIX ++ " milestone=capability_transfer_ack_verified\n";
pub const CAPABILITY_TRANSFER_CHILD_DESTROYED =
    PREFIX ++ " milestone=capability_transfer_child_destroyed\n";
pub const CAPABILITY_TRANSFER_ENDPOINTS_DESTROYED =
    PREFIX ++ " milestone=capability_transfer_endpoints_destroyed\n";
pub const FAULT_CHILD_STARTED = PREFIX ++ " milestone=fault_child_started\n";
pub const FAULT_CHILD_YIELDING = PREFIX ++ " milestone=fault_child_yielding\n";
pub const ROOT_RESUMED_AFTER_FAULT_CHILD_YIELD =
    PREFIX ++ " milestone=root_resumed_after_fault_child_yield\n";
pub const FAULT_CHILD_RESUMED = PREFIX ++ " milestone=fault_child_resumed\n";
pub const CHILD_FAULT_FORMAT = PREFIX ++ " CHILD_FAULT kind={s}\n";
pub const FAULT_CHILD_DESTROYED = PREFIX ++ " milestone=fault_child_destroyed\n";
pub const ROOT_RESUMED_AFTER_CHILDREN = PREFIX ++ " milestone=root_resumed_after_children\n";
pub const EXIT_FORMAT = PREFIX ++ " EXIT status={d}\n";

pub const ordered_milestones = [_][]const u8{
    ROOT_PROCESS_PREPARED,
    KERNEL_INITIALIZED,
    USERSPACE_ENTERED,
    BOOT_INFO_VALIDATED,
    BOOT_MODULES_VALIDATED,
    PHYSICAL_MEMORY_ALLOCATED,
    ADDRESS_SPACE_CAPABILITY_ACQUIRED,
    MEMORY_OBJECT_CAPABILITY_ACQUIRED,
    MEMORY_OBJECT_MAPPED,
    USERSPACE_HEAP_VERIFIED,
    COOPERATIVE_YIELD_COMPLETED,
    IPC_CHILD_STARTED,
    ROOT_RESUMED_AFTER_IPC_CHILD_BLOCKED,
    IPC_REQUEST_SENT,
    IPC_REQUEST_VERIFIED,
    IPC_REPLY_SENT,
    IPC_REPLY_VERIFIED,
    IPC_CHILD_DESTROYED,
    IPC_ENDPOINTS_DESTROYED,
    CAPABILITY_TRANSFER_CHILD_STARTED,
    ROOT_RESUMED_AFTER_TRANSFER_CHILD_BLOCKED,
    CAPABILITY_TRANSFER_SENT,
    CAPABILITY_TRANSFER_RECEIVED,
    CAPABILITY_TRANSFER_RIGHTS_ATTENUATED,
    CAPABILITY_TRANSFER_ACK_SENT,
    CAPABILITY_TRANSFER_ACK_VERIFIED,
    CAPABILITY_TRANSFER_CHILD_DESTROYED,
    CAPABILITY_TRANSFER_ENDPOINTS_DESTROYED,
    FAULT_CHILD_STARTED,
    FAULT_CHILD_YIELDING,
    ROOT_RESUMED_AFTER_FAULT_CHILD_YIELD,
    FAULT_CHILD_RESUMED,
    FAULT_CHILD_DESTROYED,
    ROOT_RESUMED_AFTER_CHILDREN,
};
