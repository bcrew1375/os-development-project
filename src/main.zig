const abi = @import("abi");
const memory_manager = @import("memory_manager.zig");

const MANAGED_REGION_START: usize = 0x0100_0000;
const MANAGED_REGION_SIZE: usize = 0x0000_1000;

pub export fn _start(boot_info: *const abi.boot_info.BootInfo) callconv(.c) noreturn {
    debugWrite("root: started\n");

    if (boot_info.magic == abi.boot_info.BOOT_INFO_MAGIC and boot_info.version == abi.boot_info.BOOT_INFO_VERSION) {
        debugWrite("root: boot info received\n");
    } else {
        debugWrite("root: invalid boot info\n");
    }

    const address_space = memory_manager.createAddressSpace() orelse {
        debugWrite("root: failed to acquire address-space capability\n");
        exit(abi.syscall.EXIT_FAILURE);
    };
    debugWrite("root: acquired address-space capability\n");

    const memory_object = memory_manager.createMemoryObject(MANAGED_REGION_SIZE) orelse {
        debugWrite("root: failed to acquire memory-object capability\n");
        exit(abi.syscall.EXIT_FAILURE);
    };
    debugWrite("root: acquired memory-object capability\n");

    if (!memory_manager.mapMemoryObject(
        address_space,
        memory_object,
        MANAGED_REGION_START,
        MANAGED_REGION_SIZE,
        memory_manager.MAP_READ | memory_manager.MAP_WRITE,
    )) {
        debugWrite("root: failed to map managed memory object using capabilities\n");
        exit(abi.syscall.EXIT_FAILURE);
    }
    debugWrite("root: mapped managed memory object using capabilities\n");

    exit(abi.syscall.EXIT_SUCCESS);
}

fn debugWrite(message: []const u8) void {
    _ = abi.syscall.syscall3(
        @intFromEnum(abi.syscall.SyscallNumber.debug_write),
        @intFromPtr(message.ptr),
        message.len,
        0,
    );
}

fn exit(status: u32) noreturn {
    _ = abi.syscall.syscall3(@intFromEnum(abi.syscall.SyscallNumber.exit), status, 0, 0);
    while (true) {}
}
