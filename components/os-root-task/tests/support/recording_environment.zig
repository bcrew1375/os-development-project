const abi = @import("abi");
const boot_fixtures = @import("boot_fixtures.zig");
const memory_management = @import("memory_management");
const startup = @import("startup");

const bootstrap_memory = memory_management.bootstrap;
const valid_boot_modules = boot_fixtures.valid_boot_modules;
const valid_physical_memory = boot_fixtures.valid_physical_memory;

pub const Syscall = union(enum) {
    three: struct { number: u32, arguments: [3]usize },
    five: struct { number: u32, arguments: [5]usize },
};

pub const RecordingEnvironment = struct {
    pub var syscalls: [12]Syscall = undefined;
    pub var syscall_count: usize = 0;
    var responses: [12]u32 = undefined;
    var response_count: usize = 0;
    var response_index: usize = 0;
    pub var diagnostics: [24][]const u8 = undefined;
    pub var diagnostic_count: usize = 0;
    var managed_memory: [4 * startup.INITIAL_HEAP_EXTENT_SIZE]u8 align(4096) = undefined;

    pub fn reset(configured_responses: []const u32) void {
        syscall_count = 0;
        response_count = configured_responses.len;
        response_index = 0;
        @memcpy(responses[0..configured_responses.len], configured_responses);
        diagnostic_count = 0;
        @memset(&managed_memory, 0);
    }

    pub fn syscall3(number: u32, argument0: usize, argument1: usize, argument2: usize) callconv(.c) u32 {
        syscalls[syscall_count] = .{ .three = .{
            .number = number,
            .arguments = .{ argument0, argument1, argument2 },
        } };
        syscall_count += 1;
        return nextResponse();
    }

    pub fn syscall5(
        number: u32,
        argument0: usize,
        argument1: usize,
        argument2: usize,
        argument3: usize,
        argument4: usize,
    ) callconv(.c) u32 {
        syscalls[syscall_count] = .{ .five = .{
            .number = number,
            .arguments = .{ argument0, argument1, argument2, argument3, argument4 },
        } };
        syscall_count += 1;
        return nextResponse();
    }

    pub fn debugWrite(message: []const u8) void {
        diagnostics[diagnostic_count] = message;
        diagnostic_count += 1;
    }

    pub fn yield() u32 {
        return syscall3(@intFromEnum(abi.syscall.SyscallNumber.yield), 0, 0, 0);
    }

    pub fn physicalMemoryDescriptors(
        _: *const abi.boot_info.BootInfo,
    ) bootstrap_memory.Error![]const abi.boot_info.PhysicalMemoryInfo {
        return &valid_physical_memory;
    }

    pub fn bootModuleDescriptors(
        boot_info: *const abi.boot_info.BootInfo,
    ) error{}![]const abi.boot_info.BootModuleInfo {
        return valid_boot_modules[0..boot_info.module_count];
    }

    pub fn rootHeapBounds() struct { start: usize, end: usize } {
        return .{ .start = 0x0100_0000, .end = 0x0101_0000 };
    }

    pub fn mappedMemoryAddress(virtual_start: usize, size: usize) ?usize {
        if (virtual_start < 0x0100_0000) return null;
        const offset = virtual_start - 0x0100_0000;
        if (offset > managed_memory.len or size > managed_memory.len - offset) return null;
        return @intFromPtr(&managed_memory) + offset;
    }

    fn nextResponse() u32 {
        if (response_index >= response_count) return abi.syscall.SYSCALL_FAILURE;
        defer response_index += 1;
        return responses[response_index];
    }
};
