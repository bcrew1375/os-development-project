const abi = @import("abi");
const memory_manager = @import("memory_manager");
const startup = @import("startup");
const std = @import("std");

const Syscall = union(enum) {
    three: struct { number: u32, arguments: [3]usize },
    five: struct { number: u32, arguments: [5]usize },
};

const RecordingEnvironment = struct {
    var syscalls: [8]Syscall = undefined;
    var syscall_count: usize = 0;
    var responses: [8]u32 = undefined;
    var response_count: usize = 0;
    var response_index: usize = 0;
    var diagnostics: [16][]const u8 = undefined;
    var diagnostic_count: usize = 0;

    fn reset(configured_responses: []const u32) void {
        syscall_count = 0;
        response_count = configured_responses.len;
        response_index = 0;
        @memcpy(responses[0..configured_responses.len], configured_responses);
        diagnostic_count = 0;
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

    fn nextResponse() u32 {
        if (response_index >= response_count) return abi.syscall.SYSCALL_FAILURE;
        defer response_index += 1;
        return responses[response_index];
    }
};

const manager = memory_manager.MemoryManager(RecordingEnvironment);

fn validBootInfo() abi.boot_info.BootInfo {
    return .{
        .magic = abi.boot_info.BOOT_INFO_MAGIC,
        .version = abi.boot_info.BOOT_INFO_VERSION,
        .module_count = 0,
        .modules_address = 0,
    };
}

fn expectDiagnostic(index: usize, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, RecordingEnvironment.diagnostics[index]);
}

test "memory manager emits address-space and region syscalls" {
    RecordingEnvironment.reset(&.{ 42, abi.syscall.SYSCALL_SUCCESS });
    const address_space = manager.createAddressSpace().?;
    try std.testing.expectEqual(@as(u32, 42), address_space.capability);
    try std.testing.expect(manager.mapRegion(address_space, 0x2000, 0x3000));

    const create_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.create_address_space), create_call.number);
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, create_call.arguments);
    const map_call = RecordingEnvironment.syscalls[1].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.map_memory), map_call.number);
    try std.testing.expectEqual([_]usize{ 42, 0x2000, 0x3000 }, map_call.arguments);

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectEqual(@as(?memory_manager.AddressSpace, null), manager.createAddressSpace());

    RecordingEnvironment.reset(&.{abi.syscall.SYSCALL_FAILURE});
    try std.testing.expect(!manager.mapRegion(address_space, 0x2000, 0x3000));
}

test "memory manager emits memory-object mapping syscall and flags" {
    RecordingEnvironment.reset(&.{ 71, abi.syscall.SYSCALL_SUCCESS });
    const memory_object = manager.createMemoryObject(0x5000).?;
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const permissions = memory_manager.MAP_READ | memory_manager.MAP_WRITE | memory_manager.MAP_EXECUTE;
    try std.testing.expect(manager.mapMemoryObject(address_space, memory_object, 0x8000, 0x5000, permissions));

    const create_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.create_memory_object), create_call.number);
    try std.testing.expectEqual([_]usize{ 0x5000, 0, 0 }, create_call.arguments);
    const map_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(@intFromEnum(abi.syscall.SyscallNumber.map_memory_object), map_call.number);
    try std.testing.expectEqual([_]usize{ 19, 71, 0x8000, 0x5000, permissions }, map_call.arguments);

    RecordingEnvironment.reset(&.{ 71, abi.syscall.SYSCALL_FAILURE });
    const failed_object = manager.createMemoryObject(0x1000).?;
    try std.testing.expect(!manager.mapMemoryObject(address_space, failed_object, 0, 0x1000, 0));

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectEqual(@as(?memory_manager.MemoryObject, null), manager.createMemoryObject(0x1000));
}

test "memory manager forwards every permission flag combination" {
    const address_space = memory_manager.AddressSpace{ .capability = 19 };
    const memory_object = memory_manager.MemoryObject{ .capability = 71 };

    for (0..8) |permission_flags| {
        RecordingEnvironment.reset(&.{abi.syscall.SYSCALL_SUCCESS});
        try std.testing.expect(manager.mapMemoryObject(
            address_space,
            memory_object,
            0x8000,
            0x1000,
            @intCast(permission_flags),
        ));
        try std.testing.expectEqual(
            permission_flags,
            RecordingEnvironment.syscalls[0].five.arguments[4],
        );
    }
}

test "startup rejects invalid boot information before capability syscalls" {
    var boot_info = validBootInfo();
    boot_info.magic = 0;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(@as(usize, 3), RecordingEnvironment.diagnostic_count);
    try expectDiagnostic(0, abi.system_smoke.USERSPACE_ENTERED);
    try expectDiagnostic(1, "root: started\n");
    try expectDiagnostic(2, "root: invalid boot info\n");

    boot_info = validBootInfo();
    boot_info.version += 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
}

test "startup stops after each capability or mapping failure" {
    const boot_info = validBootInfo();

    RecordingEnvironment.reset(&.{abi.capability.INVALID_CAPABILITY});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 1), RecordingEnvironment.syscall_count);
    try expectDiagnostic(4, "root: failed to acquire address-space capability\n");

    RecordingEnvironment.reset(&.{ 11, abi.capability.INVALID_CAPABILITY });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 2), RecordingEnvironment.syscall_count);
    try expectDiagnostic(6, "root: failed to acquire memory-object capability\n");

    RecordingEnvironment.reset(&.{ 11, 22, abi.syscall.SYSCALL_FAILURE });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 3), RecordingEnvironment.syscall_count);
    try expectDiagnostic(8, "root: failed to map managed memory object using capabilities\n");
}

test "startup completes capability-based memory setup in order" {
    const boot_info = validBootInfo();
    RecordingEnvironment.reset(&.{ 11, 22, abi.syscall.SYSCALL_SUCCESS });

    try std.testing.expectEqual(abi.syscall.EXIT_SUCCESS, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 3), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(@as(usize, 10), RecordingEnvironment.diagnostic_count);
    try expectDiagnostic(0, abi.system_smoke.USERSPACE_ENTERED);
    try expectDiagnostic(1, "root: started\n");
    try expectDiagnostic(2, abi.system_smoke.BOOT_INFO_VALIDATED);
    try expectDiagnostic(3, "root: boot info received\n");
    try expectDiagnostic(4, abi.system_smoke.ADDRESS_SPACE_CAPABILITY_ACQUIRED);
    try expectDiagnostic(5, "root: acquired address-space capability\n");
    try expectDiagnostic(6, abi.system_smoke.MEMORY_OBJECT_CAPABILITY_ACQUIRED);
    try expectDiagnostic(7, "root: acquired memory-object capability\n");
    try expectDiagnostic(8, abi.system_smoke.MEMORY_OBJECT_MAPPED);
    try expectDiagnostic(9, "root: mapped managed memory object using capabilities\n");

    const map_call = RecordingEnvironment.syscalls[2].five;
    try std.testing.expectEqual(
        [_]usize{
            11,
            22,
            startup.MANAGED_REGION_START,
            startup.MANAGED_REGION_SIZE,
            memory_manager.MAP_READ | memory_manager.MAP_WRITE,
        },
        map_call.arguments,
    );
}
