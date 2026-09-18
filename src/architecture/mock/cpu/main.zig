pub const Operation = union(enum) {
    unrecoverable_halt,
    enter_user_mode: struct {
        entry_point: usize,
        stack_top: usize,
        argument0: usize,
    },
};

var lastOperation: ?Operation = null;

pub fn unrecoverableHalt() noreturn {
    lastOperation = .unrecoverable_halt;
    @panic("mock CPU unrecoverable halt");
}

pub fn enterUserMode(entry_point: usize, stack_top: usize, argument0: usize) noreturn {
    lastOperation = .{ .enter_user_mode = .{
        .entry_point = entry_point,
        .stack_top = stack_top,
        .argument0 = argument0,
    } };
    @panic("mock architecture cannot enter user mode");
}

pub fn resetForTest() void {
    lastOperation = null;
}

pub fn getLastOperationForTest() ?Operation {
    return lastOperation;
}
