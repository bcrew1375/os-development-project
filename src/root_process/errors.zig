//! Shared error set for kernel root-process preparation.

const arch = @import("arch");
const shared = @import("shared");

pub const RootProcessLaunchError = error{
    RootProcessModuleMissing,
    InvalidBootModuleRange,
    RootAddressSpaceMappingMissing,
    BootModuleWindowExhausted,
} || shared.executable.elf.ElfLoadError || arch.MmuError;
