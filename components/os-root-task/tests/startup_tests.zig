const abi = @import("abi");
const memory_management = @import("memory_management");
const startup = @import("startup");
const std = @import("std");

const boot_fixtures = @import("support/boot_fixtures.zig");
const diagnostic_assertions = @import("support/diagnostic_assertions.zig");
const RecordingEnvironment = @import("support/recording_environment.zig").RecordingEnvironment;
const expectDiagnostic = diagnostic_assertions.expectDiagnostic;
const memory_manager = memory_management.operations;
const validBootInfo = boot_fixtures.validBootInfo;
const valid_physical_memory = boot_fixtures.valid_physical_memory;

test "startup rejects invalid boot information before capability syscalls" {
    var boot_info = validBootInfo();
    boot_info.magic = 0;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(@as(usize, 3), RecordingEnvironment.diagnostic_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 0, abi.system_smoke.USERSPACE_ENTERED);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 1, "root: started\n");
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 2, "root: invalid boot info\n");

    boot_info = validBootInfo();
    boot_info.version += 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);

    boot_info = validBootInfo();
    boot_info.module_count = 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 2, "root: missing delegated boot module\n");

    boot_info = validBootInfo();
    boot_info.module_count = abi.boot_info.MAX_BOOT_MODULES + 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 2, "root: invalid boot modules\n");

    boot_info = validBootInfo();
    boot_info.physical_memory_count = abi.boot_info.MAX_PHYSICAL_MEMORY_DESCRIPTORS + 1;
    RecordingEnvironment.reset(&.{});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 0), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 2, "root: invalid physical memory descriptors\n");
}

test "startup stops after each capability or mapping failure" {
    const boot_info = validBootInfo();

    RecordingEnvironment.reset(&.{abi.syscall.errorResult(.out_of_resources)});
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 1), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 6, "root: failed to acquire address-space capability\n");

    RecordingEnvironment.reset(&.{ 11, abi.syscall.errorResult(.out_of_resources) });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 2), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 6, "root: failed to initialize userspace heap\n");

    RecordingEnvironment.reset(&.{
        11,
        21,
        abi.syscall.errorResult(.out_of_resources),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 4), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.delete_physical_memory),
        RecordingEnvironment.syscalls[3].three.number,
    );
    try std.testing.expectEqual([_]usize{ 21, 0, 0 }, RecordingEnvironment.syscalls[3].three.arguments);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 6, "root: failed to initialize userspace heap\n");

    RecordingEnvironment.reset(&.{
        11,
        21,
        21,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.SYSCALL_SUCCESS,
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 5), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.destroy_memory_object),
        RecordingEnvironment.syscalls[4].three.number,
    );
    try std.testing.expectEqual([_]usize{ 21, 0, 0 }, RecordingEnvironment.syscalls[4].three.arguments);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 6, "root: failed to initialize userspace heap\n");
}

test "startup retains allocator ownership when kernel cleanup fails" {
    const boot_info = validBootInfo();

    RecordingEnvironment.reset(&.{
        11,
        21,
        abi.syscall.errorResult(.out_of_resources),
        abi.syscall.errorResult(.internal_failure),
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 4), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 6, "root: failed to initialize userspace heap\n");

    RecordingEnvironment.reset(&.{
        11,
        21,
        21,
        abi.syscall.errorResult(.invalid_permissions),
        abi.syscall.errorResult(.internal_failure),
    });
    try std.testing.expectEqual(abi.syscall.EXIT_FAILURE, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 5), RecordingEnvironment.syscall_count);
    try expectDiagnostic(&RecordingEnvironment.diagnostics, 6, "root: failed to initialize userspace heap\n");
}

test "startup completes capability-based memory setup in order" {
    const boot_info = validBootInfo();
    RecordingEnvironment.reset(&.{
        11,
        21,
        21,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
        abi.syscall.SYSCALL_SUCCESS,
    });

    try std.testing.expectEqual(abi.syscall.EXIT_SUCCESS, startup.run(RecordingEnvironment, &boot_info));
    try std.testing.expectEqual(@as(usize, 7), RecordingEnvironment.syscall_count);
    try std.testing.expectEqual(@as(usize, 18), RecordingEnvironment.diagnostic_count);
    const diagnostics = &RecordingEnvironment.diagnostics;
    try expectDiagnostic(diagnostics, 0, abi.system_smoke.USERSPACE_ENTERED);
    try expectDiagnostic(diagnostics, 1, "root: started\n");
    try expectDiagnostic(diagnostics, 2, abi.system_smoke.BOOT_INFO_VALIDATED);
    try expectDiagnostic(diagnostics, 3, "root: boot info received\n");
    try expectDiagnostic(diagnostics, 4, abi.system_smoke.BOOT_MODULES_VALIDATED);
    try expectDiagnostic(diagnostics, 5, "root: boot modules validated\n");
    try expectDiagnostic(diagnostics, 6, abi.system_smoke.PHYSICAL_MEMORY_ALLOCATED);
    try expectDiagnostic(diagnostics, 7, "root: allocated heap physical memory\n");
    try expectDiagnostic(diagnostics, 8, abi.system_smoke.ADDRESS_SPACE_CAPABILITY_ACQUIRED);
    try expectDiagnostic(diagnostics, 9, "root: acquired address-space capability\n");
    try expectDiagnostic(diagnostics, 10, abi.system_smoke.MEMORY_OBJECT_CAPABILITY_ACQUIRED);
    try expectDiagnostic(diagnostics, 11, "root: acquired heap memory-object capability\n");
    try expectDiagnostic(diagnostics, 12, abi.system_smoke.MEMORY_OBJECT_MAPPED);
    try expectDiagnostic(diagnostics, 13, "root: mapped initial userspace heap extent\n");
    try expectDiagnostic(diagnostics, 14, abi.system_smoke.USERSPACE_HEAP_VERIFIED);
    try expectDiagnostic(diagnostics, 15, "root: userspace heap verified\n");
    try expectDiagnostic(diagnostics, 16, abi.system_smoke.COOPERATIVE_YIELD_COMPLETED);
    try expectDiagnostic(diagnostics, 17, "root: cooperative yield completed\n");

    const current_call = RecordingEnvironment.syscalls[0].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.current_address_space),
        current_call.number,
    );
    try std.testing.expectEqual([_]usize{ 0, 0, 0 }, current_call.arguments);

    const retype_call = RecordingEnvironment.syscalls[1].five;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.retype_untyped_memory),
        retype_call.number,
    );
    try std.testing.expectEqual(valid_physical_memory[0].capability, retype_call.arguments[0]);
    try std.testing.expectEqual(@as(usize, 0), retype_call.arguments[1]);
    try std.testing.expectEqual(@as(usize, 0), retype_call.arguments[2]);

    const create_call = RecordingEnvironment.syscalls[2].three;
    try std.testing.expectEqual(
        @intFromEnum(abi.syscall.SyscallNumber.create_memory_object),
        create_call.number,
    );
    try std.testing.expectEqual([_]usize{ 21, 0, 0 }, create_call.arguments);

    const map_call = RecordingEnvironment.syscalls[3].five;
    try std.testing.expectEqual(
        [_]usize{
            11,
            21,
            0x0100_0000,
            startup.INITIAL_HEAP_EXTENT_SIZE,
            memory_manager.MAP_READ | memory_manager.MAP_WRITE,
        },
        map_call.arguments,
    );
    for (RecordingEnvironment.syscalls[4..7]) |yield_call| {
        try std.testing.expectEqual(
            @intFromEnum(abi.syscall.SyscallNumber.yield),
            yield_call.three.number,
        );
        try std.testing.expectEqual([_]usize{ 0, 0, 0 }, yield_call.three.arguments);
    }
}
