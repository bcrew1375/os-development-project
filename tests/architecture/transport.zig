const std = @import("std");

const qemu_exit_port: u16 = 0xF4;
const com1_base_address: u16 = 0x3F8;
const coverage_port: u16 = 0xE9;

pub const ExitStatus = enum(u32) {
    success = 0,
    failure = 1,
};

pub fn initialize() void {
    out8(com1_base_address + 1, 0x00);
    out8(com1_base_address + 3, 0x80);
    out8(com1_base_address, 0x03);
    out8(com1_base_address + 1, 0x00);
    out8(com1_base_address + 3, 0x03);
    out8(com1_base_address + 2, 0xC7);
    out8(com1_base_address + 4, 0x0B);
}

const Writer = std.io.GenericWriter(void, error{}, struct {
    fn write(_: void, data: []const u8) error{}!usize {
        for (data) |character| writeCharacter(character);
        return data.len;
    }
}.write);

pub fn writer() Writer {
    return .{ .context = {} };
}

const CoverageWriter = std.io.GenericWriter(void, error{}, struct {
    fn write(_: void, data: []const u8) error{}!usize {
        for (data) |byte| out8(coverage_port, byte);
        return data.len;
    }
}.write);

pub fn coverageWriter() CoverageWriter {
    return .{ .context = {} };
}

pub fn exit(status: ExitStatus) noreturn {
    out32(qemu_exit_port, @intFromEnum(status));
    while (true) {
        asm volatile ("hlt");
    }
}

fn writeCharacter(character: u8) void {
    while ((in8(com1_base_address + 5) & 0x20) == 0) {}
    out8(com1_base_address, character);
}

fn in8(port: u16) u8 {
    return asm volatile ("in %[port], %al"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .eax = true, .dx = true, .memory = true });
}

fn out8(port: u16, value: u8) void {
    asm volatile ("out %[value], %[port]"
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
        : .{ .dx = true, .al = true, .memory = true });
}

fn out32(port: u16, value: u32) void {
    asm volatile ("out %[value], %[port]"
        :
        : [port] "{dx}" (port),
          [value] "{eax}" (value),
        : .{ .dx = true, .eax = true, .memory = true });
}
