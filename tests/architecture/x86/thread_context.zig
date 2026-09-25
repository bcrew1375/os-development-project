const arch = @import("arch");
const builtin = @import("builtin");
const framework = @import("../framework.zig");

var round_trip_current: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;
var round_trip_next: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;
var observed_next_root: arch.AddressSpaceRoot = .{ .value = 0 };
var observed_next_privilege_stack: usize = 0;
var round_trip_count: usize = 0;
var kernel_continuation_current: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;
var kernel_continuation_next: arch.ThreadContextHandle = arch.INVALID_THREAD_CONTEXT_HANDLE;
var observed_kernel_root: arch.AddressSpaceRoot = .{ .value = 0 };
var observed_kernel_privilege_stack: usize = 0;

pub fn initialStateUsesBoundedKernelStack() !void {
    const root = currentAddressSpaceRoot();
    const user_stack_pointer = validUserStackPointer(0x0080_0000);
    const argument: usize = 0x1234;
    const available_before = arch.thread_context.availableCount();
    const handle = try arch.thread_context.create(.{
        .address_space_root = root,
        .entry_point = 0x0040_0000,
        .stack_pointer = user_stack_pointer,
        .argument = argument,
    });
    defer arch.thread_context.destroy(handle) catch {};

    const bounds = try arch.thread_context.getKernelStackBoundsForTest(handle);
    const initial = try arch.thread_context.getInitialStateForTest(handle);
    try framework.expectEqual(available_before - 1, arch.thread_context.availableCount());
    try framework.expectEqual(
        arch.thread_context.KERNEL_STACK_SIZE,
        bounds.end - bounds.start,
    );
    try framework.expectEqual(@as(usize, 0), bounds.start % 4096);
    try framework.expect(initial.saved_stack_pointer >= bounds.start);
    try framework.expect(initial.saved_stack_pointer < bounds.end);
    try framework.expectEqual(@as(usize, 0x0040_0000), initial.entry_point);
    try framework.expectEqual(user_stack_pointer, initial.user_stack_pointer);
    try framework.expectEqual(@as(usize, 3), initial.code_selector & 0x3);
    try framework.expectEqual(@as(usize, 3), initial.data_selector & 0x3);
    try framework.expect(initial.code_selector != initial.data_selector);
    try framework.expect((initial.flags & 0x202) == 0x202);
    if (builtin.cpu.arch == .x86_64) {
        try framework.expectEqual(argument, initial.argument);
    }
}

pub fn switchRoundTripRestoresAddressSpaceAndPrivilegeStack() !void {
    @call(.never_inline, arch.boot.finishBoot, .{});

    const original_root = currentAddressSpaceRoot();
    const alternate_root = try arch.mmu.createAddressSpaceRoot();
    const current = try arch.thread_context.create(.{
        .address_space_root = original_root,
        .entry_point = 0x0040_0000,
        .stack_pointer = validUserStackPointer(0x0080_0000),
        .argument = 0,
    });
    const next = try arch.thread_context.create(.{
        .address_space_root = alternate_root,
        .entry_point = 0x0040_1000,
        .stack_pointer = validUserStackPointer(0x0081_0000),
        .argument = 0,
    });
    round_trip_current = current;
    round_trip_next = next;
    observed_next_root = .{ .value = 0 };
    observed_next_privilege_stack = 0;
    round_trip_count = 0;

    try arch.thread_context.prepareKernelContinuationForTest(next, &alternateContinuation);
    try arch.thread_context.bindCurrentForTest(current);
    for (0..3) |_| {
        try arch.thread_context.switchContext(current, next);
    }

    const current_bounds = try arch.thread_context.getKernelStackBoundsForTest(current);
    const next_bounds = try arch.thread_context.getKernelStackBoundsForTest(next);
    try framework.expectEqual(alternate_root.value, observed_next_root.value);
    try framework.expectEqual(next_bounds.end, observed_next_privilege_stack);
    try framework.expectEqual(original_root.value, currentAddressSpaceRoot().value);
    try framework.expectEqual(
        current_bounds.end,
        arch.thread_context.getPrivilegeStackForTest(),
    );
    try framework.expectEqual(@as(usize, 3), round_trip_count);
}

fn alternateContinuation() callconv(.c) noreturn {
    while (true) {
        observed_next_root = currentAddressSpaceRoot();
        observed_next_privilege_stack = arch.thread_context.getPrivilegeStackForTest();
        round_trip_count += 1;
        arch.thread_context.switchContext(round_trip_next, round_trip_current) catch {
            @panic("thread context round-trip failed");
        };
    }
}

pub fn kernelContinuationRoundTripRestoresAddressSpaceAndPrivilegeStack() !void {
    @call(.never_inline, arch.boot.finishBoot, .{});

    const original_root = currentAddressSpaceRoot();
    const alternate_root = try arch.mmu.createAddressSpaceRoot();
    const current = try arch.thread_context.create(.{
        .address_space_root = original_root,
        .entry_point = 0x0040_0000,
        .stack_pointer = validUserStackPointer(0x0080_0000),
        .argument = 0,
    });
    const available_before = arch.thread_context.availableCount();
    const continuation = try arch.thread_context.createKernelContinuation(.{
        .address_space_root = alternate_root,
        .entry = &kernelContinuation,
    });
    try framework.expectEqual(available_before, arch.thread_context.availableCount());
    const duplicate_result = arch.thread_context.createKernelContinuation(.{
        .address_space_root = alternate_root,
        .entry = &kernelContinuation,
    });
    if (duplicate_result) |_| {
        return error.ExpectedKernelContinuationAlreadyExists;
    } else |err| {
        try framework.expect(err == error.KernelContinuationAlreadyExists);
    }

    kernel_continuation_current = current;
    kernel_continuation_next = continuation;
    observed_kernel_root = .{ .value = 0 };
    observed_kernel_privilege_stack = 0;
    try arch.thread_context.bindCurrentForTest(current);
    try arch.thread_context.switchContext(current, continuation);

    const current_bounds = try arch.thread_context.getKernelStackBoundsForTest(current);
    try framework.expectEqual(alternate_root.value, observed_kernel_root.value);
    try framework.expect(observed_kernel_privilege_stack != 0);
    try framework.expect(observed_kernel_privilege_stack != current_bounds.end);
    try framework.expectEqual(original_root.value, currentAddressSpaceRoot().value);
    try framework.expectEqual(
        current_bounds.end,
        arch.thread_context.getPrivilegeStackForTest(),
    );
}

fn kernelContinuation() callconv(.c) noreturn {
    observed_kernel_root = currentAddressSpaceRoot();
    observed_kernel_privilege_stack = arch.thread_context.getPrivilegeStackForTest();
    arch.thread_context.switchContext(
        kernel_continuation_next,
        kernel_continuation_current,
    ) catch @panic("kernel continuation round-trip failed");
    unreachable;
}

fn currentAddressSpaceRoot() arch.AddressSpaceRoot {
    return arch.thread_context.getCurrentAddressSpaceRootForTest();
}

fn validUserStackPointer(stack_top: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86 => stack_top - 4,
        .x86_64 => stack_top - 8,
        else => @compileError("unsupported architecture"),
    };
}
