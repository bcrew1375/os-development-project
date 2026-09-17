const builtin = @import("builtin");
const std = @import("std");

const boot_text_section = if (builtin.cpu.arch == .x86) ".multiboot.text" else ".text";
const coverage_data_section = if (builtin.cpu.arch == .x86) ".multiboot.coverage_data" else ".data";
const max_coverage_points = 65_536;

extern const __start___sancov_guards: u32;
extern const __stop___sancov_guards: u32;

var seen: [max_coverage_points / 8]u8 linksection(coverage_data_section) = @splat(0);
export var __sancov_lowest_stack: usize = 0;

pub const Header = extern struct {
    magic: [8]u8 = "OSCV0001".*,
    version: u16 = 1,
    architecture: u8,
    pointer_width: u8 = @sizeOf(usize),
    point_count: u32,
    bitmap_byte_count: u32,
};

pub fn pointCount() usize {
    @disableInstrumentation();
    return (@intFromPtr(&__stop___sancov_guards) -
        @intFromPtr(&__start___sancov_guards)) / @sizeOf(u32);
}

pub fn writeFrame(writer: anytype) void {
    @disableInstrumentation();
    const point_count = pointCount();
    if (point_count > max_coverage_points) return;
    const bitmap_byte_count = (point_count + 7) / 8;
    const header: Header = .{
        .architecture = switch (builtin.cpu.arch) {
            .x86 => 1,
            .x86_64 => 2,
            else => 0,
        },
        .point_count = @intCast(point_count),
        .bitmap_byte_count = @intCast(bitmap_byte_count),
    };
    writer.writeAll(std.mem.asBytes(&header)) catch return;
    writer.writeAll(seen[0..bitmap_byte_count]) catch return;
}

pub noinline fn traceProgramCounter(guard: *u32) linksection(boot_text_section) callconv(.c) void {
    @disableInstrumentation();
    const start = @intFromPtr(&__start___sancov_guards);
    const address = @intFromPtr(guard);
    if (address < start) return;
    const index = (address - start) / @sizeOf(u32);
    if (index >= max_coverage_points) return;
    seen[index / 8] |= @as(u8, 1) << @intCast(index % 8);
}

comptime {
    @export(&traceProgramCounter, .{ .name = "__sanitizer_cov_trace_pc_guard" });
}

export fn __sanitizer_cov_trace_pc_guard_init(_: [*]u32, _: [*]u32) linksection(boot_text_section) void {
    @disableInstrumentation();
}
