const arch = @import("../../architecture.zig");
const std = @import("std");

const MAX_CONSOLE_BYTES = 4096;
const MAX_COLOR_CHANGES = 128;

pub const State = struct {
    console_initialization_count: usize = 0,
    timer_initialization_count: usize = 0,
    timer_frequency: ?usize = null,
    timer_interrupt_count: usize = 0,
    console_bytes: [MAX_CONSOLE_BYTES]u8 = undefined,
    console_byte_count: usize = 0,
    color_changes: [MAX_COLOR_CHANGES]arch.TextColor = undefined,
    color_change_count: usize = 0,
};

var state = State{};

pub fn initializeTimer(frequency: usize) void {
    state.timer_initialization_count += 1;
    state.timer_frequency = frequency;
    resetTimerInterruptCount();
}

pub fn resetTimerInterruptCount() void {
    state.timer_interrupt_count = 0;
}

pub fn getTimerInterruptCount() usize {
    return state.timer_interrupt_count;
}

pub fn recordTimerInterruptForTest() void {
    state.timer_interrupt_count +|= 1;
}

pub fn initializeConsole() void {
    state.console_initialization_count += 1;
}

pub fn setColor(color: arch.TextColor) void {
    if (state.color_change_count >= state.color_changes.len) {
        @panic("mock platform color observation capacity exceeded");
    }
    state.color_changes[state.color_change_count] = color;
    state.color_change_count += 1;
}

pub const Writer = std.Io.Writer;

fn drain(_: *Writer, data: []const []const u8, _: usize) Writer.Error!usize {
    var written: usize = 0;
    for (data) |bytes| {
        if (bytes.len > state.console_bytes.len - state.console_byte_count) {
            @panic("mock platform console observation capacity exceeded");
        }
        @memcpy(
            state.console_bytes[state.console_byte_count..][0..bytes.len],
            bytes,
        );
        state.console_byte_count += bytes.len;
        written += bytes.len;
    }
    return written;
}

const writer_vtable: Writer.VTable = .{ .drain = drain };
var writer_instance: Writer = .{ .vtable = &writer_vtable, .buffer = &.{} };

pub fn writer() *Writer {
    return &writer_instance;
}

pub fn resetForTest() void {
    state = State{};
}

pub fn getStateForTest() *const State {
    return &state;
}

pub fn getConsoleBytesForTest() []const u8 {
    return state.console_bytes[0..state.console_byte_count];
}

pub fn getColorChangesForTest() []const arch.TextColor {
    return state.color_changes[0..state.color_change_count];
}
