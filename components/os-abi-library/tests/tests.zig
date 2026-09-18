const std = @import("std");
const abi = @import("abi");
const shared = @import("shared");

test "BootInfo ABI layout is stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(abi.boot_info.BootInfo));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(abi.boot_info.BootInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.boot_info.BootInfo, "magic"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(abi.boot_info.BootInfo, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.boot_info.BootInfo, "module_count"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(abi.boot_info.BootInfo, "modules_address"));
}

test "BootModuleInfo ABI layout is stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(abi.boot_info.BootModuleInfo));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(abi.boot_info.BootModuleInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.boot_info.BootModuleInfo, "physical_start"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.boot_info.BootModuleInfo, "physical_end"));
}

test "Capability rights containment is explicit" {
    const all = abi.capability.Rights{
        .read = true,
        .write = true,
        .execute = true,
        .manage = true,
    };

    try std.testing.expect(all.contains(.{ .read = true }));
    try std.testing.expect(all.contains(.{ .read = true, .write = true }));
    try std.testing.expect(!(abi.capability.Rights{ .read = true }).contains(.{ .write = true }));
}

test "ELF parser rejects non-ELF bytes" {
    const image = "not an elf image";
    try std.testing.expectError(
        error.InvalidElfImage,
        shared.executable.elf.parseLoadableImage(image, 4096),
    );
}

const elf32_header_size = @sizeOf(std.elf.Elf32_Ehdr);
const elf32_program_header_size = @sizeOf(std.elf.Elf32_Phdr);
const elf64_header_size = @sizeOf(std.elf.Elf64_Ehdr);
const elf64_program_header_size = @sizeOf(std.elf.Elf64_Phdr);

fn writeInteger(comptime T: type, image: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, image[offset..][0..@sizeOf(T)], value, .little);
}

fn initializeIdentification(image: []u8, class: u8) void {
    @memcpy(image[0..4], std.elf.MAGIC);
    image[std.elf.EI_CLASS] = class;
    image[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    image[std.elf.EI_VERSION] = 1;
}

fn setElf32ProgramHeader(
    image: []u8,
    index: usize,
    program_type: u32,
    file_offset: u32,
    virtual_address: u32,
    file_size: u32,
    memory_size: u32,
    flags: u32,
) void {
    const offset = elf32_header_size + index * elf32_program_header_size;
    writeInteger(u32, image, offset, program_type);
    writeInteger(u32, image, offset + 4, file_offset);
    writeInteger(u32, image, offset + 8, virtual_address);
    writeInteger(u32, image, offset + 16, file_size);
    writeInteger(u32, image, offset + 20, memory_size);
    writeInteger(u32, image, offset + 24, flags);
}

fn makeElf32() [0x240]u8 {
    var image = [_]u8{0} ** 0x240;
    initializeIdentification(&image, std.elf.ELFCLASS32);
    writeInteger(u16, &image, 16, @intFromEnum(std.elf.ET.EXEC));
    writeInteger(u16, &image, 18, @intFromEnum(std.elf.EM.@"386"));
    writeInteger(u32, &image, 20, 1);
    writeInteger(u32, &image, 24, 0x1010);
    writeInteger(u32, &image, 28, elf32_header_size);
    writeInteger(u16, &image, 40, elf32_header_size);
    writeInteger(u16, &image, 42, elf32_program_header_size);
    writeInteger(u16, &image, 44, 2);
    setElf32ProgramHeader(&image, 0, std.elf.PT_LOAD, 0x200, 0x1003, 4, 0x1000, 5);
    setElf32ProgramHeader(&image, 1, std.elf.PT_LOAD, 0x220, 0x4000, 8, 0x2000, 6);
    @memcpy(image[0x200..0x204], "text");
    @memcpy(image[0x220..0x228], "data1234");
    return image;
}

fn setElf64ProgramHeader(
    image: []u8,
    index: usize,
    program_type: u32,
    file_offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
    flags: u32,
) void {
    const offset = elf64_header_size + index * elf64_program_header_size;
    writeInteger(u32, image, offset, program_type);
    writeInteger(u32, image, offset + 4, flags);
    writeInteger(u64, image, offset + 8, file_offset);
    writeInteger(u64, image, offset + 16, virtual_address);
    writeInteger(u64, image, offset + 32, file_size);
    writeInteger(u64, image, offset + 40, memory_size);
}

fn makeElf64() [0x240]u8 {
    var image = [_]u8{0} ** 0x240;
    initializeIdentification(&image, std.elf.ELFCLASS64);
    writeInteger(u16, &image, 16, @intFromEnum(std.elf.ET.EXEC));
    writeInteger(u16, &image, 18, @intFromEnum(std.elf.EM.X86_64));
    writeInteger(u32, &image, 20, 1);
    writeInteger(u64, &image, 24, 0x400010);
    writeInteger(u64, &image, 32, elf64_header_size);
    writeInteger(u16, &image, 52, elf64_header_size);
    writeInteger(u16, &image, 54, elf64_program_header_size);
    writeInteger(u16, &image, 56, 2);
    setElf64ProgramHeader(&image, 0, std.elf.PT_LOAD, 0x200, 0x400003, 4, 0x1000, 5);
    setElf64ProgramHeader(&image, 1, std.elf.PT_LOAD, 0x220, 0x404000, 8, 0x2000, 6);
    @memcpy(image[0x200..0x204], "text");
    @memcpy(image[0x220..0x228], "data1234");
    return image;
}

test "ELF parser reads valid ELF32 loadable segments" {
    const image = makeElf32();
    const loadable = try shared.executable.elf.parseLoadableImage(&image, 4096);
    try std.testing.expectEqual(@as(u64, 0x1010), loadable.entry_point);
    try std.testing.expectEqual(@as(u64, 0x1000), loadable.virtual_start);
    try std.testing.expectEqual(@as(u64, 0x6000), loadable.virtual_end);
    try std.testing.expectEqual(@as(usize, 2), loadable.segment_count);

    const text = try shared.executable.elf.getLoadableSegment(&image, 0);
    try std.testing.expectEqual(@as(u64, 0x1003), text.virtual_address);
    try std.testing.expect(text.permissions.readable);
    try std.testing.expect(!text.permissions.writeable);
    try std.testing.expect(text.permissions.executable);
}

test "ELF parser reads valid ELF64 loadable segments" {
    const image = makeElf64();
    const loadable = try shared.executable.elf.parseLoadableImage(&image, 4096);
    try std.testing.expectEqual(@as(u64, 0x400010), loadable.entry_point);
    try std.testing.expectEqual(@as(u64, 0x400000), loadable.virtual_start);
    try std.testing.expectEqual(@as(u64, 0x406000), loadable.virtual_end);

    const data = try shared.executable.elf.getLoadableSegment(&image, 1);
    try std.testing.expectEqual(@as(usize, 0x220), data.file_offset);
    try std.testing.expectEqual(@as(usize, 8), data.file_size);
    try std.testing.expect(data.permissions.readable);
    try std.testing.expect(data.permissions.writeable);
    try std.testing.expect(!data.permissions.executable);
    try std.testing.expectError(
        error.InvalidLoadSegment,
        shared.executable.elf.getLoadableSegment(&image, 2),
    );
}

test "ELF parser rejects unsupported identification and executable headers" {
    var image = makeElf32();
    image[std.elf.EI_CLASS] = 0xff;
    try std.testing.expectError(error.UnsupportedElfClass, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf32();
    image[std.elf.EI_DATA] = std.elf.ELFDATA2MSB;
    try std.testing.expectError(error.UnsupportedElfEndian, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf32();
    image[std.elf.EI_VERSION] = 0;
    try std.testing.expectError(error.UnsupportedElfVersion, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf32();
    writeInteger(u16, &image, 16, @intFromEnum(std.elf.ET.DYN));
    try std.testing.expectError(error.UnsupportedElfType, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf32();
    writeInteger(u16, &image, 18, @intFromEnum(std.elf.EM.X86_64));
    try std.testing.expectError(error.UnsupportedElfMachine, shared.executable.elf.parseLoadableImage(&image, 4096));
}

test "ELF parser rejects malformed program header tables" {
    var image = makeElf64();
    writeInteger(u16, &image, 54, elf64_program_header_size - 1);
    try std.testing.expectError(error.InvalidProgramHeaderTable, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    writeInteger(u64, &image, 32, image.len - 1);
    try std.testing.expectError(error.InvalidProgramHeaderTable, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    writeInteger(u16, &image, 56, 0);
    try std.testing.expectError(error.InvalidProgramHeaderTable, shared.executable.elf.parseLoadableImage(&image, 4096));
}

test "ELF parser rejects invalid loadable segments" {
    var image = makeElf64();
    setElf64ProgramHeader(&image, 0, std.elf.PT_LOAD, 0x200, 0x400000, 8, 4, 5);
    try std.testing.expectError(error.InvalidLoadSegment, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    setElf64ProgramHeader(&image, 0, std.elf.PT_LOAD, image.len - 2, 0x400000, 4, 4, 5);
    try std.testing.expectError(error.InvalidLoadSegment, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    setElf64ProgramHeader(&image, 0, std.elf.PT_LOAD, 0x200, 0x400000, 0, 0, 5);
    try std.testing.expectError(error.EmptyLoadSegment, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    setElf64ProgramHeader(&image, 0, 0, 0, 0, 0, 0, 0);
    setElf64ProgramHeader(&image, 1, 0, 0, 0, 0, 0, 0);
    try std.testing.expectError(error.NoLoadableSegments, shared.executable.elf.parseLoadableImage(&image, 4096));
}

test "ELF parser rejects arithmetic overflow and invalid page sizes" {
    var image = makeElf64();
    setElf64ProgramHeader(&image, 0, std.elf.PT_LOAD, 0x200, std.math.maxInt(u64), 1, 2, 5);
    try std.testing.expectError(error.InvalidLoadSegment, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    setElf64ProgramHeader(&image, 0, std.elf.PT_LOAD, 0x200, std.math.maxInt(u64) - 1, 1, 1, 5);
    try std.testing.expectError(error.InvalidLoadSegment, shared.executable.elf.parseLoadableImage(&image, 4096));

    image = makeElf64();
    try std.testing.expectError(error.InvalidLoadSegment, shared.executable.elf.parseLoadableImage(&image, 0));
    try std.testing.expectError(error.InvalidLoadSegment, shared.executable.elf.parseLoadableImage(&image, 3));
}
