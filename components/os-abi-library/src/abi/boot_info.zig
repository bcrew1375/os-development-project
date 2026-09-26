//! Boot information ABI passed from the kernel to the initial user process.

/// Sentinel used to validate that a `BootInfo` pointer came from this kernel.
pub const BOOT_INFO_MAGIC: u32 = 0xB007_1F00;
/// Version of the boot information ABI.
pub const BOOT_INFO_VERSION: u32 = 3;
/// Maximum number of physical-memory descriptors supplied during bootstrap.
pub const MAX_PHYSICAL_MEMORY_DESCRIPTORS: usize = 64;
/// Maximum number of boot modules retained and described during bootstrap.
pub const MAX_BOOT_MODULES: usize = 16;

/// Descriptor identifies ordinary allocatable RAM.
pub const PHYSICAL_MEMORY_NORMAL_RAM: u32 = 1 << 0;
/// Descriptor identifies device or memory-mapped I/O storage.
pub const PHYSICAL_MEMORY_DEVICE: u32 = 1 << 1;

/// Fixed-layout boot information block supplied to the root process.
pub const BootInfo = extern struct {
    /// Must equal `BOOT_INFO_MAGIC`.
    magic: u32,
    /// Must equal `BOOT_INFO_VERSION`.
    version: u32,
    /// Number of boot modules described by `modules_address`.
    module_count: u32,
    /// Physical or ABI-defined address of the first `BootModuleInfo` entry.
    modules_address: u32,
    /// Number of `PhysicalMemoryInfo` entries supplied to the root task.
    physical_memory_count: u32,
    /// Userspace address of the first `PhysicalMemoryInfo` entry.
    physical_memory_address: u32,
};

/// Fixed-layout descriptor for a boot module made available to userspace.
pub const BootModuleInfo = extern struct {
    /// Inclusive physical start address of the module.
    physical_start: u64,
    /// Root-task userspace address of the first exact module byte.
    virtual_start: u64,
    /// Exact module size in bytes.
    size: u64,
};

/// Fixed-layout physical-memory descriptor paired with authority when delegated.
pub const PhysicalMemoryInfo = extern struct {
    /// Inclusive physical start address.
    physical_start: u64,
    /// Size in bytes; the exclusive end is `physical_start + size`.
    size: u64,
    /// `PHYSICAL_MEMORY_*` attribute bits.
    attributes: u32,
    /// Capability authorizing use, or `INVALID_CAPABILITY` before delegation.
    capability: u32,
};
