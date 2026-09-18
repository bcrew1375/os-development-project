const kernel_initialization = @import("kernel_initialization");
const std = @import("std");

const TestError = error{RootPreparationFailed};

const TestPreparedRootProcess = struct {
    address_space_root: usize,
    entry_point: usize,
    initial_stack_pointer: usize,
};

const Operation = union(enum) {
    initialize_terminal,
    message: []const u8,
    prepare_root_process: usize,
    set_error_color,
    preparation_failure: []const u8,
    finish_boot,
    initialize_interrupts,
    enable_interrupts,
};

const RecordingServices = struct {
    pub const PreparedRootProcess = TestPreparedRootProcess;

    var operations: [12]Operation = undefined;
    var operation_count: usize = 0;
    var prepare_error: ?TestError = null;
    var prepared = PreparedRootProcess{
        .address_space_root = 7,
        .entry_point = 0x401000,
        .initial_stack_pointer = 0xbffff8,
    };

    fn reset(error_to_return: ?TestError) void {
        operation_count = 0;
        prepare_error = error_to_return;
    }

    pub fn initializeTerminal() void {
        record(.initialize_terminal);
    }

    pub fn writeMessage(message: []const u8) void {
        record(.{ .message = message });
    }

    pub fn prepareRootProcess(address_space: *usize) TestError!PreparedRootProcess {
        record(.{ .prepare_root_process = address_space.* });
        if (prepare_error) |err| return err;
        return prepared;
    }

    pub fn setErrorColor() void {
        record(.set_error_color);
    }

    pub fn writePreparationFailure(err: anyerror) void {
        record(.{ .preparation_failure = @errorName(err) });
    }

    pub fn finishBoot() void {
        record(.finish_boot);
    }

    pub fn initializeInterrupts() void {
        record(.initialize_interrupts);
    }

    pub fn enableInterrupts() void {
        record(.enable_interrupts);
    }

    fn record(operation: Operation) void {
        operations[operation_count] = operation;
        operation_count += 1;
    }
};

test "Kernel initialization returns prepared process after ordered startup" {
    RecordingServices.reset(null);
    var root_address_space: usize = 99;

    const prepared = try kernel_initialization.initialize(
        RecordingServices,
        &root_address_space,
    );

    try std.testing.expectEqual(RecordingServices.prepared, prepared);
    try std.testing.expectEqual(@as(usize, 7), RecordingServices.operation_count);
    try std.testing.expectEqual(Operation.initialize_terminal, RecordingServices.operations[0]);
    try std.testing.expectEqualStrings(
        "Preparing first user process...\n",
        RecordingServices.operations[1].message,
    );
    try std.testing.expectEqual(@as(usize, 99), RecordingServices.operations[2].prepare_root_process);
    try std.testing.expectEqual(Operation.finish_boot, RecordingServices.operations[3]);
    try std.testing.expectEqual(Operation.initialize_interrupts, RecordingServices.operations[4]);
    try std.testing.expectEqual(Operation.enable_interrupts, RecordingServices.operations[5]);
    try std.testing.expectEqualStrings(
        "Launching first user process...\n",
        RecordingServices.operations[6].message,
    );
}

test "Kernel initialization reports preparation failure and stops" {
    RecordingServices.reset(TestError.RootPreparationFailed);
    var root_address_space: usize = 44;

    try std.testing.expectError(
        TestError.RootPreparationFailed,
        kernel_initialization.initialize(RecordingServices, &root_address_space),
    );

    try std.testing.expectEqual(@as(usize, 5), RecordingServices.operation_count);
    try std.testing.expectEqual(Operation.initialize_terminal, RecordingServices.operations[0]);
    try std.testing.expectEqualStrings(
        "Preparing first user process...\n",
        RecordingServices.operations[1].message,
    );
    try std.testing.expectEqual(@as(usize, 44), RecordingServices.operations[2].prepare_root_process);
    try std.testing.expectEqual(Operation.set_error_color, RecordingServices.operations[3]);
    try std.testing.expectEqualStrings(
        "RootPreparationFailed",
        RecordingServices.operations[4].preparation_failure,
    );
}
