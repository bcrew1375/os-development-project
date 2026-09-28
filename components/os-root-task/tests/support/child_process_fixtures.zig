const abi = @import("abi");
const process_management = @import("process_management");

const child_process = process_management.child_process;

pub const ChildRollbackEnvironment = struct {
    pub var syscall_numbers: [32]u32 = undefined;
    pub var syscall_arguments: [32][5]usize = undefined;
    pub var syscall_count: usize = 0;
    var next_capability: u32 = 100;
    pub var loader_memory: [child_process.STACK_SIZE + 0x4000]u8 align(4096) = undefined;

    pub fn reset() void {
        syscall_count = 0;
        next_capability = 100;
        @memset(&syscall_arguments, .{ 0, 0, 0, 0, 0 });
        @memset(&loader_memory, 0);
    }

    pub fn syscall3(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
    ) callconv(.c) u32 {
        record(number, .{ argument0, argument1, argument2, 0, 0 });
        const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(number);
        return switch (syscall_number) {
            .create_capability_space,
            .create_address_space,
            .create_thread,
            .install_capability,
            => nextCapability(),
            .create_memory_object => nextCapability(),
            .start_thread => abi.syscall.errorResult(.invalid_state),
            else => abi.syscall.SYSCALL_SUCCESS,
        };
    }

    pub fn syscall5(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
        argument3: usize,
        argument4: usize,
    ) callconv(.c) u32 {
        record(number, .{ argument0, argument1, argument2, argument3, argument4 });
        const syscall_number: abi.syscall.SyscallNumber = @enumFromInt(number);
        return switch (syscall_number) {
            .retype_untyped_memory => nextCapability(),
            else => abi.syscall.SYSCALL_SUCCESS,
        };
    }

    pub fn mappedMemoryAddress(virtual_start: usize, size: usize) ?usize {
        if (virtual_start < child_process.LOADER_WINDOW_START) return null;
        const offset = virtual_start - child_process.LOADER_WINDOW_START;
        if (offset > loader_memory.len or size > loader_memory.len - offset) return null;
        return @intFromPtr(&loader_memory) + offset;
    }

    fn record(number: u32, arguments: [5]usize) void {
        syscall_numbers[syscall_count] = number;
        syscall_arguments[syscall_count] = arguments;
        syscall_count += 1;
    }

    fn nextCapability() u32 {
        defer next_capability += 1;
        return next_capability;
    }
};

pub const MemoryObjectFailureEnvironment = struct {
    pub var syscall_numbers: [16]u32 = undefined;
    pub var syscall_count: usize = 0;
    var next_capability: u32 = 200;

    pub fn reset() void {
        syscall_count = 0;
        next_capability = 200;
    }

    pub fn syscall3(number: u32, _: usize, _: usize, _: usize) callconv(.c) u32 {
        syscall_numbers[syscall_count] = number;
        syscall_count += 1;
        return switch (@as(abi.syscall.SyscallNumber, @enumFromInt(number))) {
            .create_capability_space, .create_address_space => nextCapability(),
            .create_memory_object => abi.syscall.errorResult(.out_of_resources),
            else => abi.syscall.SYSCALL_SUCCESS,
        };
    }

    pub fn syscall5(
        number: u32,
        _: usize,
        _: usize,
        _: usize,
        _: usize,
        _: usize,
    ) callconv(.c) u32 {
        syscall_numbers[syscall_count] = number;
        syscall_count += 1;
        return switch (@as(abi.syscall.SyscallNumber, @enumFromInt(number))) {
            .retype_untyped_memory => nextCapability(),
            else => abi.syscall.SYSCALL_SUCCESS,
        };
    }

    fn nextCapability() u32 {
        defer next_capability += 1;
        return next_capability;
    }
};
