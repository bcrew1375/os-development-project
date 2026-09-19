const arch = @import("arch");
const kernel_common = @import("kernel_common");
const memory_management = kernel_common.memory_management;
const pmm = memory_management.physical_memory;
const vmm = memory_management.virtual_memory;
const kernelHeap = memory_management.kernel_heap;
const terminal = kernel_common.terminal;
const kernel_initialization = @import("kernel_initialization.zig");
const launch_root_process = @import("launch_root_process.zig");
const TextColor = @import("arch").TextColor;

const std = @import("std");
const abi = @import("abi");

const KERNEL_VMA_TOTAL = 16;
const ROOT_VMA_TOTAL = 32;

var kernelVmaBacking: [KERNEL_VMA_TOTAL]vmm.VirtualMemoryArea = undefined;
var rootVmaBacking: [ROOT_VMA_TOTAL]vmm.VirtualMemoryArea = undefined;

var kernelAddressSpace: vmm.AddressSpace = vmm.AddressSpace{
    .virtual_memory_areas = &kernelVmaBacking,
    .length = 0,
};

var rootAddressSpace: vmm.AddressSpace = vmm.AddressSpace{
    .virtual_memory_areas = &rootVmaBacking,
    .length = 0,
};

pub export fn kernelMain() void {
    // const coreMemoryPermissions = vmm.MemoryPermissions{
    //     .readable = true,
    //     .writeable = false,
    //     .executable = true,
    //     .user_accessible = false,
    // };

    // const heapMemoryPermissions = vmm.MemoryPermissions{
    //     .readable = true,
    //     .writeable = true,
    //     .executable = true,
    //     .user_accessible = false,
    // };

    // vmm.setAddressSpace(&kernelAddressSpace);

    // const directMapStartAddress = arch.mmu.getDirectMapVirtualAddress();
    // const availableRam = arch.mmu.getMaxAvailableAddress();

    // const directMapSize = @min(@as(u64, arch.mmu.getDirectMapMaxSize()), availableRam);
    // const directMapEndAddress = directMapStartAddress + @as(usize, @intCast(directMapSize));

    // vmm.map(&kernelAddressSpace, directMapStartAddress, directMapEndAddress, coreMemoryPermissions) catch |err| {
    //     arch.platform.setColor(TextColor.RED);
    //     arch.platform.writer().print("Kernel core address space init failed with error: {s}\n", .{@errorName(err)}) catch {};
    //     arch.cpu.unrecoverableHalt();
    // };

    // terminal.print.printString("Initializing PMM...");
    // pmm.initialize() catch |err| {
    //     arch.platform.setColor(TextColor.RED);
    //     arch.platform.writer().print("PMM init failed with error: {s}\n", .{@errorName(err)}) catch {};
    //     arch.cpu.unrecoverableHalt();
    // };
    // terminal.print.printStringColor("done!\n", TextColor.GREEN);

    // pmm.setTrackAllocationsAsReserved(true);

    // arch.earlyAllocatorActive = false;

    // arch.boot.finishBoot();

    const prepared_root_process = kernel_initialization.initialize(
        KernelInitializationServices,
        &rootAddressSpace,
    ) catch {
        arch.cpu.unrecoverableHalt();
    };

    // arch.boot.finishBoot();

    // terminal.print.printString("Initializing interrupts...");
    // arch.interrupts.initialize();
    // terminal.print.printStringColor("done!\n", TextColor.GREEN);

    // arch.interrupts.enableInterrupts();

    // const kernelHeapStartAddress = arch.mmu.getKernelHeapVirtualAddress();
    // const kernelHeapEndAddress = kernelHeapStartAddress + arch.mmu.getKernelHeapSize();

    // vmm.map(&kernelAddressSpace, kernelHeapStartAddress, kernelHeapEndAddress, heapMemoryPermissions) catch |err| {
    //     arch.platform.setColor(TextColor.RED);
    //     arch.platform.writer().print("Kernel heap address space init failed with error: {s}\n", .{@errorName(err)}) catch {};
    //     arch.cpu.unrecoverableHalt();
    // };

    // terminal.print.printString("Initializing kernel heap...");
    // kernelHeap.initialize() catch |err| {
    //     arch.platform.setColor(TextColor.RED);
    //     arch.platform.writer().print("Kernel heap init failed with error: {s}\n", .{@errorName(err)}) catch {};
    //     arch.cpu.unrecoverableHalt();
    // };
    // terminal.print.printStringColor("done!\n", TextColor.GREEN);

    // pmm.setTrackAllocationsAsReserved(false);

    // try arch.platform.writer().print("Total Available RAM: {d} KB\n", .{pmm.getTotalAvailableRAM() / 1024});
    // try arch.platform.writer().print("Total System Reserved RAM: {d} KB\n", .{pmm.getTotalSystemReservedRAM() / 1024});
    // try arch.platform.writer().print("Current Available RAM: {d} KB\n", .{pmm.getCurrentAvailableRAM() / 1024});

    // const allocation: [*]u8 = @as([*]u8, @ptrCast(kernelHeap.kmalloc(10 * 1024 * 1024) catch |err| {
    //     arch.platform.setColor(TextColor.RED);
    //     arch.platform.writer().print("Kernel allocate failed with error: {s}\n", .{@errorName(err)}) catch {};
    //     arch.cpu.unrecoverableHalt();
    // }));

    // allocation[100000] = 12;
    // allocation[200000] = 22;
    // allocation[300000] = 32;
    // allocation[400000] = 42;
    // allocation[500000] = 52;
    // allocation[600000] = 62;
    // allocation[700000] = 72;
    // allocation[800000] = 82;
    // allocation[900000] = 92;
    // allocation[1000000] = 112;

    // try arch.platform.writer().print("Current Available RAM: {d} KB\n", .{pmm.getCurrentAvailableRAM() / 1024});
    // try arch.platform.writer().print("System Dynamic Allocation: {d} KB\n", .{kernelHeap.getDynamicAllocationSize() / 1024});

    // arch.platform.initializeTimer(10);

    launch_root_process.enterPreparedRootProcess(prepared_root_process);

    //arch.cpu.unrecoverableHalt();
}

const KernelInitializationServices = struct {
    pub const PreparedRootProcess = launch_root_process.PreparedRootProcess;

    pub fn initializeTerminal() void {
        terminal.initialize();
    }

    pub fn writeMessage(message: []const u8) void {
        terminal.print.printString(message);
    }

    pub fn writeSystemSmokeHeader() void {
        terminal.print.printString(abi.system_smoke.HEADER);
    }

    pub fn writeRootProcessPrepared() void {
        terminal.print.printString(abi.system_smoke.ROOT_PROCESS_PREPARED);
    }

    pub fn writeKernelInitialized() void {
        terminal.print.printString(abi.system_smoke.KERNEL_INITIALIZED);
    }

    pub fn prepareRootProcess(address_space: *vmm.AddressSpace) !PreparedRootProcess {
        return launch_root_process.prepareRootProcess(address_space);
    }

    pub fn setErrorColor() void {
        arch.platform.setColor(TextColor.RED);
    }

    pub fn writePreparationFailure(err: anyerror) void {
        arch.platform.writer().print(
            "First user process preparation failed with error: {s}\n",
            .{@errorName(err)},
        ) catch {};
    }

    pub fn finishBoot() void {
        arch.boot.finishBoot();
    }

    pub fn initializeInterrupts() void {
        arch.interrupts.initialize();
    }

    pub fn enableInterrupts() void {
        arch.interrupts.enableInterrupts();
    }
};

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, number: ?usize) noreturn {
    arch.interrupts.disableInterrupts();
    arch.platform.setColor(TextColor.RED);
    arch.platform.writer().writeAll("\n!KERNEL PANIC!\n") catch {};
    arch.platform.writer().writeAll(message) catch {};
    arch.platform.writer().writeAll("\n") catch {};
    _ = stack_trace;
    _ = number;
    while (true) {}
}
