//! Versioned production lifecycle records consumed by full-system smoke tests.

pub const PROTOCOL_VERSION: u32 = 3;
pub const PREFIX = "SYSTEM-SMOKE";

pub const HEADER = PREFIX ++ " protocol=3\n";
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
pub const CLEAN_CHILD_STARTED = PREFIX ++ " milestone=clean_child_started\n";
pub const CLEAN_CHILD_YIELDING = PREFIX ++ " milestone=clean_child_yielding\n";
pub const ROOT_RESUMED_AFTER_CLEAN_CHILD_YIELD =
    PREFIX ++ " milestone=root_resumed_after_clean_child_yield\n";
pub const CLEAN_CHILD_RESUMED = PREFIX ++ " milestone=clean_child_resumed\n";
pub const CHILD_EXIT_FORMAT = PREFIX ++ " CHILD_EXIT status={d}\n";
pub const CLEAN_CHILD_DESTROYED = PREFIX ++ " milestone=clean_child_destroyed\n";
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
    CLEAN_CHILD_STARTED,
    CLEAN_CHILD_YIELDING,
    ROOT_RESUMED_AFTER_CLEAN_CHILD_YIELD,
    CLEAN_CHILD_RESUMED,
    CLEAN_CHILD_DESTROYED,
    FAULT_CHILD_STARTED,
    FAULT_CHILD_YIELDING,
    ROOT_RESUMED_AFTER_FAULT_CHILD_YIELD,
    FAULT_CHILD_RESUMED,
    FAULT_CHILD_DESTROYED,
    ROOT_RESUMED_AFTER_CHILDREN,
};
