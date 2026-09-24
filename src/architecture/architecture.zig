//! Common architecture interface and selected architecture implementation facade.
//!
//! Architecture-independent kernel code imports this module to access CPU, MMU,
//! interrupt, boot, allocator, and platform services without binding to a
//! concrete hardware implementation.

const builtin = @import("builtin");
const std = @import("std");

/// Selected architecture implementation. Tests use the mock implementation.
pub const impl = if (builtin.is_test)
    @import("mock/arch.zig")
else switch (builtin.cpu.arch) {
    .x86 => @import("x86/32/arch.zig"),
    .x86_64 => @import("x86/64/arch.zig"),
    //.aarch64 => @import("aarch64/impl.zig"),
    //.riscv64 => @import("riscv64/impl.zig"),
    else => @compileError("unsupported architecture: " ++
        @tagName(builtin.cpu.arch)),
};

comptime {
    validateImpl(impl);
}

/// Early boot allocator implementation.
pub const early_allocator = impl.early_allocator;
/// Boot protocol services.
pub const boot = impl.boot;
/// CPU control services.
pub const cpu = impl.cpu;
/// Interrupt controller and descriptor-table services.
pub const interrupts = impl.interrupts;
/// Memory-management unit services.
pub const mmu = impl.mmu;
/// Bounded kernel-reserved page-table frame pool.
pub const page_table_pool = @import("page_table_pool.zig");
/// Platform device services such as console and timers.
pub const platform = impl.platform;

/// Portable terminal color names.
pub const TextColor = enum(u8) {
    BLACK,
    BLUE,
    GREEN,
    CYAN,
    RED,
    MAGENTA,
    BROWN,
    LIGHT_GRAY,
    DARK_GRAY,
    LIGHT_BLUE,
    LIGHT_GREEN,
    LIGHT_CYAN,
    LIGHT_RED,
    LIGHT_MAGENTA,
    YELLOW,
    WHITE,
};

/// Maximum number of memory map entries retained during early boot.
pub const MAX_MEMORY_MAP_ENTRIES = 128;
/// Maximum number of early reserved memory regions.
pub const MAX_EARLY_RESERVATIONS = 128;
/// Maximum number of boot modules retained by physical boot adapters.
pub const MAX_BOOT_MODULES = 16;

/// Errors exposed by architecture MMU implementations.
pub const MmuError = error{
    MemoryMapReadError,
    MappingError,
    PageTableNotPresent,
    AddressSpaceRootAllocationFailed,
    PageTablePoolExhausted,
    AddressSpacePageTableLimitReached,
};

/// Opaque architecture address-space root identifier.
pub const AddressSpaceRoot = struct {
    value: usize,
};

/// Boot-time physical memory map.
pub const MemoryMap = struct {
    entries: [MAX_MEMORY_MAP_ENTRIES]MemoryMapEntry = undefined,
    length: usize = 0,
    available_regions: usize = 0,
};

/// Single physical memory range descriptor.
pub const MemoryMapEntry = struct {
    address: u64 = undefined,
    size: u64 = undefined,
    region_type: MemoryMapRegionType = MemoryMapRegionType.RESERVED,
};
/// Classification for physical memory map ranges.
pub const MemoryMapRegionType = enum(u8) {
    AVAILABLE,
    RESERVED,
    RECLAIMABLE,
    BAD,
};

/// Reason an early memory range was reserved.
pub const ReservedMapRegionType = enum {
    TEMPORARY,
    PERSISTENT,
    KERNEL_READ_ONLY,
    KERNEL_WRITABLE,
    BOOTLOADER_DATA,
    DEVICE_MEMORY,
    PAGE_TABLE_POOL,
};

/// Single early reserved memory range.
pub const ReservedMapEntry = struct {
    address: usize,
    size: usize,
    region_type: ReservedMapRegionType,
};

/// Collection of early reserved memory ranges.
pub const ReservedMap = struct {
    entries: [MAX_EARLY_RESERVATIONS]ReservedMapEntry = undefined,
    length: usize = 0,
};

/// Boot-loaded module physical range.
pub const BootModule = struct {
    physical_start: usize,
    physical_end: usize,
};

/// Errors returned by early boot allocation and reservation operations.
pub const EarlyAllocError = error{
    OutOfReservations,
    OutOfSpace,
    InvalidSize,
    InvalidAlignment,
    InvalidMemoryMap,
};

/// Architecture page-table protection flags.
pub const PageProtection = struct {
    write: bool = false,
    user: bool = false,
    execute: bool = false,
    global: bool = false,
};

/// Decoded page-fault information supplied to the common fault handler.
pub const FaultInfo = struct {
    address: usize,
    present: bool,
    write: bool,
    user: bool,
    instruction_fetch: bool,
};

/// Performs compile-time interface validation for an architecture implementation.
pub fn validateImpl(comptime T: type) void {
    comptime {
        validateInterface(T.early_allocator, struct {
            initialize: fn () EarlyAllocError!void,
            allocate: fn (needed_size: usize, alignment: usize, region_type: ReservedMapRegionType) EarlyAllocError!*allowzero anyopaque,
            reserve: fn (address: usize, size: usize, region_type: ReservedMapRegionType) EarlyAllocError!void,
            getReservedMap: fn () *ReservedMap,
        });

        validateInterface(T.boot, struct {
            finishBoot: fn () void,
            getBootModuleCount: fn () usize,
            getBootModule: fn (index: usize) ?BootModule,
        });

        validateInterface(T.cpu, struct {
            unrecoverableHalt: fn () noreturn,
            enterUserMode: fn (entry_point: usize, stack_top: usize, argument0: usize) noreturn,
        });

        validateInterface(T.mmu, struct {
            createAddressSpaceRoot: fn () MmuError!AddressSpaceRoot,
            destroyAddressSpaceRoot: fn (root: AddressSpaceRoot) void,
            switchAddressSpaceRoot: fn (root: AddressSpaceRoot) void,
            getPhysicalAddressInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize) ?usize,
            getPhysicalAddress: fn (virtualAddress: usize) ?usize,
            isTablePresentInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize) bool,
            isTablePresent: fn (virtualAddress: usize) bool,
            ensurePageTableInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize, flags: PageProtection) MmuError!void,
            ensurePageTable: fn (virtualAddress: usize, flags: PageProtection) MmuError!void,
            getMemoryMap: fn () *MemoryMap,
            getMaximumPhysicalAddress: fn () u64,
            zeroPhysicalRange: fn (physicalStart: u64, sizeInBytes: u64) MmuError!void,
            mapPageInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: PageProtection) MmuError!void,
            mapPage: fn (virtualAddress: usize, physicalAddress: usize, flags: PageProtection) MmuError!void,
            mapTableInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize, physicalAddress: usize, flags: PageProtection) MmuError!void,
            mapTable: fn (virtualAddress: usize, physicalAddress: usize, flags: PageProtection) MmuError!void,
            unmapPageInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize) ?usize,
            unmapPage: fn (virtualAddress: usize) ?usize,
            getPageProtectionInAddressSpace: fn (root: AddressSpaceRoot, virtualAddress: usize) ?PageProtection,
            getPageProtection: fn (virtualAddress: usize) ?PageProtection,
            getMaxAvailableAddress: fn () u64,
            getDirectMapVirtualAddress: fn () u64,
            getDirectMapMaxSize: fn () u64,
            getKernelVirtualAddressStart: fn () u64,
            getPageSize: fn () usize,
            getPageTableRegionSize: fn () usize,
            getPageTablePoolAvailableFrameCount: fn () usize,
        });

        validateInterface(T.interrupts, struct {
            initialize: fn () void,
            set: fn (interruptVector: usize, address: usize, typeAttribute: usize) void,
            enableInterrupts: fn () void,
            disableInterrupts: fn () void,
            acknowledgeInterrupt: fn (vector: usize) void,
        });

        validateInterface(T.platform, struct {
            initializeTimer: fn (frequency: usize) void,
            resetTimerInterruptCount: fn () void,
            getTimerInterruptCount: fn () usize,
            initializeConsole: fn () void,
            setColor: fn (color: TextColor) void,
        });

        if (!@hasDecl(T.platform, "writer")) {
            @compileError(@typeName(T.platform) ++ " is missing 'writer' instance");
        }
        if (@TypeOf(T.platform.writer) != fn () *std.Io.Writer) {
            @compileError(@typeName(T.platform) ++ ".writer has an unexpected type");
        }
    }
}

fn validateInterface(comptime Impl: type, comptime Interface: type) void {
    const info = @typeInfo(Interface).@"struct";
    inline for (info.fields) |field| {
        if (!@hasDecl(Impl, field.name)) {
            @compileError(@typeName(Impl) ++ " is missing declaration '" ++ field.name ++ "'");
        }
        const ActualType = @TypeOf(@field(Impl, field.name));
        if (ActualType != field.type) {
            @compileError(@typeName(Impl) ++ "." ++ field.name ++ " has type: " ++ @typeName(ActualType) ++ ", expected: " ++ @typeName(field.type));
        }
    }
}
