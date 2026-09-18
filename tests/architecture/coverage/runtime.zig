const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const std = @import("std");

const runtime_text_section = if (builtin.cpu.arch == .x86) ".multiboot.text" else ".text";
const runtime_data_section = if (builtin.cpu.arch == .x86) ".multiboot.data" else ".data";
extern const __start___sancov_guards: u32;
extern const __stop___sancov_guards: u32;

var seen: [protocol.max_points / 8]u8 linksection(runtime_data_section) = @splat(0);
export var __sancov_lowest_stack: usize linksection(runtime_data_section) = 0;

pub fn instrumentationPointCount() usize {
    @disableInstrumentation();
    return (@intFromPtr(&__stop___sancov_guards) -
        @intFromPtr(&__start___sancov_guards)) / @sizeOf(u32);
}

pub fn writeFrame(writer: anytype) !void {
    @disableInstrumentation();
    const instrumentation_point_count = instrumentationPointCount();
    if (instrumentation_point_count > protocol.max_points) {
        return error.TooManyCoveragePoints;
    }
    const covered_points_bitmap_size = (instrumentation_point_count + 7) / 8;
    const header: protocol.Header = .{
        .architecture = .current(),
        .instrumentation_point_count = @intCast(instrumentation_point_count),
        .covered_points_bitmap_size = @intCast(covered_points_bitmap_size),
    };
    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(seen[0..covered_points_bitmap_size]);
}

pub noinline fn traceProgramCounter(
    guard: *u32,
) linksection(runtime_text_section) callconv(.c) void {
    @disableInstrumentation();
    const start = @intFromPtr(&__start___sancov_guards);
    const address = @intFromPtr(guard);
    if (address < start) return;
    const index = (address - start) / @sizeOf(u32);
    if (index >= protocol.max_points) return;
    seen[index / 8] |= @as(u8, 1) << @intCast(index % 8);
}

comptime {
    @export(&traceProgramCounter, .{ .name = "__sanitizer_cov_trace_pc_guard" });
}

export fn __sanitizer_cov_trace_pc_guard_init(
    _: [*]u32,
    _: [*]u32,
) linksection(runtime_text_section) void {
    @disableInstrumentation();
}
