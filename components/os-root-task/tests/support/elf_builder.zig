const std = @import("std");

pub const ChildElfSegment = struct {
    file_offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
    flags: u32,
};

pub fn initializeChildElf64(
    image: []u8,
    entry_point: u64,
    segments: []const ChildElfSegment,
) void {
    @memset(image, 0);
    @memcpy(image[0..4], std.elf.MAGIC);
    image[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    image[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    image[std.elf.EI_VERSION] = 1;
    writeTestInteger(u16, image, 16, @intFromEnum(std.elf.ET.EXEC));
    writeTestInteger(u16, image, 18, @intFromEnum(std.elf.EM.X86_64));
    writeTestInteger(u32, image, 20, 1);
    writeTestInteger(u64, image, 24, entry_point);
    writeTestInteger(u64, image, 32, @sizeOf(std.elf.Elf64_Ehdr));
    writeTestInteger(u16, image, 52, @sizeOf(std.elf.Elf64_Ehdr));
    writeTestInteger(u16, image, 54, @sizeOf(std.elf.Elf64_Phdr));
    writeTestInteger(u16, image, 56, @intCast(segments.len));
    for (segments, 0..) |segment, index| {
        const offset = @sizeOf(std.elf.Elf64_Ehdr) + index * @sizeOf(std.elf.Elf64_Phdr);
        writeTestInteger(u32, image, offset, std.elf.PT_LOAD);
        writeTestInteger(u32, image, offset + 4, segment.flags);
        writeTestInteger(u64, image, offset + 8, segment.file_offset);
        writeTestInteger(u64, image, offset + 16, segment.virtual_address);
        writeTestInteger(u64, image, offset + 32, segment.file_size);
        writeTestInteger(u64, image, offset + 40, segment.memory_size);
    }
}

pub fn initializeChildElf32(image: []u8) void {
    @memset(image, 0);
    @memcpy(image[0..4], std.elf.MAGIC);
    image[std.elf.EI_CLASS] = std.elf.ELFCLASS32;
    image[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    image[std.elf.EI_VERSION] = 1;
    writeTestInteger(u16, image, 16, @intFromEnum(std.elf.ET.EXEC));
    writeTestInteger(u16, image, 18, @intFromEnum(std.elf.EM.@"386"));
    writeTestInteger(u32, image, 20, 1);
    writeTestInteger(u32, image, 24, 0x0040_0000);
    writeTestInteger(u32, image, 28, @sizeOf(std.elf.Elf32_Ehdr));
    writeTestInteger(u16, image, 40, @sizeOf(std.elf.Elf32_Ehdr));
    writeTestInteger(u16, image, 42, @sizeOf(std.elf.Elf32_Phdr));
    writeTestInteger(u16, image, 44, 1);
    const offset = @sizeOf(std.elf.Elf32_Ehdr);
    writeTestInteger(u32, image, offset, std.elf.PT_LOAD);
    writeTestInteger(u32, image, offset + 4, 0x100);
    writeTestInteger(u32, image, offset + 8, 0x0040_0000);
    writeTestInteger(u32, image, offset + 16, 1);
    writeTestInteger(u32, image, offset + 20, 0x1000);
    writeTestInteger(u32, image, offset + 24, 5);
}

fn writeTestInteger(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
