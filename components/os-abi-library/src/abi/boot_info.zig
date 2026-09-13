//! Boot information ABI passed from the kernel to the initial user process.

/// Sentinel used to validate that a `BootInfo` pointer came from this kernel.
pub const BOOT_INFO_MAGIC: u32 = 0xB007_1F00;
/// Version of the boot information ABI.
pub const BOOT_INFO_VERSION: u32 = 1;

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
};

/// Fixed-layout descriptor for a boot module made available to userspace.
pub const BootModuleInfo = extern struct {
    /// Inclusive physical start address of the module.
    physical_start: u64,
    /// Exclusive physical end address of the module.
    physical_end: u64,
};
