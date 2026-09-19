//! Versioned production lifecycle records consumed by full-system smoke tests.

pub const PROTOCOL_VERSION: u32 = 1;
pub const PREFIX = "SYSTEM-SMOKE";

pub const HEADER = PREFIX ++ " protocol=1\n";
pub const ROOT_PROCESS_PREPARED = PREFIX ++ " milestone=root_process_prepared\n";
pub const KERNEL_INITIALIZED = PREFIX ++ " milestone=kernel_initialized\n";
pub const USERSPACE_ENTERED = PREFIX ++ " milestone=userspace_entered\n";
pub const BOOT_INFO_VALIDATED = PREFIX ++ " milestone=boot_info_validated\n";
pub const ADDRESS_SPACE_CAPABILITY_ACQUIRED =
    PREFIX ++ " milestone=address_space_capability_acquired\n";
pub const MEMORY_OBJECT_CAPABILITY_ACQUIRED =
    PREFIX ++ " milestone=memory_object_capability_acquired\n";
pub const MEMORY_OBJECT_MAPPED = PREFIX ++ " milestone=memory_object_mapped\n";
pub const EXIT_FORMAT = PREFIX ++ " EXIT status={d}\n";

pub const ordered_milestones = [_][]const u8{
    ROOT_PROCESS_PREPARED,
    KERNEL_INITIALIZED,
    USERSPACE_ENTERED,
    BOOT_INFO_VALIDATED,
    ADDRESS_SPACE_CAPABILITY_ACQUIRED,
    MEMORY_OBJECT_CAPABILITY_ACQUIRED,
    MEMORY_OBJECT_MAPPED,
};
