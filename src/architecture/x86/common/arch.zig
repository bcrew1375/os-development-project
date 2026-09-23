const validateImpl = @import("../../architecture.zig").validateImpl;

pub fn makeArchitecture(comptime implementation: anytype) type {
    return struct {
        comptime {
            validateImpl(@This());
        }

        pub const early_allocator = struct {
            pub const initialize = implementation.early_allocator.initialize;
            pub const allocate = implementation.early_allocator.allocate;
            pub const reserve = implementation.early_allocator.reserve;
            pub const getReservedMap = implementation.early_allocator.getReservedMap;
        };

        pub const boot = struct {
            pub const finishBoot = implementation.boot.finishBoot;
            pub const getBootModuleCount = implementation.boot.getBootModuleCount;
            pub const getBootModule = implementation.boot.getBootModule;
        };

        pub const cpu = struct {
            pub const unrecoverableHalt = implementation.cpu.unrecoverableHalt;
            pub const enterUserMode = implementation.cpu.enterUserMode;
        };

        pub const interrupts = struct {
            pub const initialize = implementation.interrupts.idt.initialize;
            pub const set = implementation.interrupts.idt.set;
            pub const enableInterrupts = implementation.interrupts.enableInterrupts;
            pub const disableInterrupts = implementation.interrupts.disableInterrupts;
            pub const acknowledgeInterrupt = implementation.interrupts.acknowledgeInterrupt;
        };

        pub const mmu = struct {
            pub const createAddressSpaceRoot = implementation.mmu.createAddressSpaceRoot;
            pub const destroyAddressSpaceRoot = implementation.mmu.destroyAddressSpaceRoot;
            pub const switchAddressSpaceRoot = implementation.mmu.switchAddressSpaceRoot;
            pub const getPhysicalAddressInAddressSpace = implementation.mmu.getPhysicalAddressInAddressSpace;
            pub const getPhysicalAddress = implementation.mmu.getPhysicalAddress;
            pub const isTablePresentInAddressSpace = implementation.mmu.isTablePresentInAddressSpace;
            pub const isTablePresent = implementation.mmu.isTablePresent;
            pub const ensurePageTableInAddressSpace = implementation.mmu.ensurePageTableInAddressSpace;
            pub const ensurePageTable = implementation.mmu.ensurePageTable;
            pub const getMemoryMap = implementation.mmu.getMemoryMap;
            pub const getMaximumPhysicalAddress = implementation.mmu.getMaximumPhysicalAddress;
            pub const mapPageInAddressSpace = implementation.mmu.mapPageInAddressSpace;
            pub const mapPage = implementation.mmu.mapPage;
            pub const mapTableInAddressSpace = implementation.mmu.mapTableInAddressSpace;
            pub const mapTable = implementation.mmu.mapTable;
            pub const unmapPageInAddressSpace = implementation.mmu.unmapPageInAddressSpace;
            pub const unmapPage = implementation.mmu.unmapPage;
            pub const getPageProtectionInAddressSpace = implementation.mmu.getPageProtectionInAddressSpace;
            pub const getPageProtection = implementation.mmu.getPageProtection;
            pub const getMaxAvailableAddress = implementation.mmu.getMaxAvailableAddress;
            pub const getDirectMapVirtualAddress = implementation.mmu.getDirectMapVirtualAddress;
            pub const getDirectMapMaxSize = implementation.mmu.getDirectMapMaxSize;
            pub const getKernelVirtualAddressStart = implementation.mmu.getKernelVirtualAddressStart;
            pub const getKernelHeapVirtualAddress = implementation.mmu.getKernelHeapVirtualAddress;
            pub const getKernelHeapSize = implementation.mmu.getKernelHeapSize;
            pub const getPageSize = implementation.mmu.getPageSize;
            pub const getPageTableRegionSize = implementation.mmu.getPageTableRegionSize;
            pub const getPageTablePoolAvailableFrameCount = implementation.mmu.getPageTablePoolAvailableFrameCount;
        };

        pub const platform = struct {
            pub const initializeTimer = implementation.platform.time.initializeTimer;
            pub const resetTimerInterruptCount = implementation.platform.time.resetInterruptCount;
            pub const getTimerInterruptCount = implementation.platform.time.getInterruptCount;
            pub const initializeConsole = implementation.platform.console.initialize;
            pub const setColor = implementation.platform.console.setColor;
            pub const writer = implementation.platform.console.writer;
        };
    };
}
