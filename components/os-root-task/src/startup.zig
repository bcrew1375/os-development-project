const abi = @import("abi");
const bootstrap_memory = @import("bootstrap_memory");
const memory_manager = @import("memory_manager");

pub const MANAGED_REGION_START: usize = 0x0100_0000;
pub const MANAGED_REGION_SIZE: usize = 0x0000_1000;

pub fn run(comptime Environment: type, boot_info: *const abi.boot_info.BootInfo) u32 {
    const manager = memory_manager.MemoryManager(Environment);
    Environment.debugWrite(abi.system_smoke.USERSPACE_ENTERED);
    Environment.debugWrite("root: started\n");

    if (boot_info.magic != abi.boot_info.BOOT_INFO_MAGIC or
        boot_info.version != abi.boot_info.BOOT_INFO_VERSION)
    {
        Environment.debugWrite("root: invalid boot info\n");
        return abi.syscall.EXIT_FAILURE;
    }
    bootstrap_memory.validateBootInfo(boot_info) catch {
        Environment.debugWrite("root: invalid physical memory descriptors\n");
        return abi.syscall.EXIT_FAILURE;
    };
    Environment.debugWrite(abi.system_smoke.BOOT_INFO_VALIDATED);
    Environment.debugWrite("root: boot info received\n");

    const address_space = manager.currentAddressSpace() catch {
        Environment.debugWrite("root: failed to acquire address-space capability\n");
        return abi.syscall.EXIT_FAILURE;
    };
    Environment.debugWrite(abi.system_smoke.ADDRESS_SPACE_CAPABILITY_ACQUIRED);
    Environment.debugWrite("root: acquired address-space capability\n");

    const memory_object = manager.createMemoryObject(MANAGED_REGION_SIZE) catch {
        Environment.debugWrite("root: failed to acquire memory-object capability\n");
        return abi.syscall.EXIT_FAILURE;
    };
    Environment.debugWrite(abi.system_smoke.MEMORY_OBJECT_CAPABILITY_ACQUIRED);
    Environment.debugWrite("root: acquired memory-object capability\n");

    manager.mapMemoryObject(
        address_space,
        memory_object,
        MANAGED_REGION_START,
        MANAGED_REGION_SIZE,
        memory_manager.MAP_READ | memory_manager.MAP_WRITE,
    ) catch {
        Environment.debugWrite("root: failed to map managed memory object using capabilities\n");
        return abi.syscall.EXIT_FAILURE;
    };
    Environment.debugWrite(abi.system_smoke.MEMORY_OBJECT_MAPPED);
    Environment.debugWrite("root: mapped managed memory object using capabilities\n");
    return abi.syscall.EXIT_SUCCESS;
}
