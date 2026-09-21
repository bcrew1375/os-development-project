const port_io = @import("port_io.zig");
const std = @import("std");

const com1_base_address: u16 = 0x3F8;

const PortOffset = enum(u16) {
    data = 0,
    interrupt_enable = 1,
    fifo_control = 2,
    line_control = 3,
    modem_control = 4,
    line_status = 5,
};

pub fn initialize() void {
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.interrupt_enable), 0x00);
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.line_control), 0x80);
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.data), 0x03);
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.interrupt_enable), 0x00);
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.line_control), 0x03);
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.fifo_control), 0xC7);
    port_io.out8(com1_base_address + @intFromEnum(PortOffset.modem_control), 0x0B);
}

fn isTransmitHoldingRegisterEmpty() bool {
    return (port_io.in8(com1_base_address + @intFromEnum(PortOffset.line_status)) & 0x20) != 0;
}

pub fn writeCharacter(character: u8) void {
    while (!isTransmitHoldingRegisterEmpty()) {}
    port_io.out8(com1_base_address, character);
}

pub fn writeString(string: []const u8) void {
    for (string) |character| {
        writeCharacter(character);
    }
}

const Writer = std.Io.Writer;

fn drain(_: *Writer, data: []const []const u8, _: usize) Writer.Error!usize {
    var written: usize = 0;
    for (data) |chunk| {
        writeString(chunk);
        written += chunk.len;
    }
    return written;
}

const writer_vtable: Writer.VTable = .{ .drain = drain };
var writer_instance: Writer = .{ .vtable = &writer_vtable, .buffer = &.{} };

pub fn writer() *Writer {
    return &writer_instance;
}
