const std = @import("std");

pub const Segment = struct {
    file_offset: u32,
    virtual_address: u32,
    file_size: u32,
    memory_size: u32,
    flags: u32,
};

pub fn initializeElf32(
    image: []u8,
    entry_point: u32,
    segments: []const Segment,
) void {
    const header_size = @sizeOf(std.elf.Elf32_Ehdr);
    const program_header_size = @sizeOf(std.elf.Elf32_Phdr);
    const program_header_table_end = header_size + segments.len * program_header_size;
    std.debug.assert(program_header_table_end <= image.len);

    @memset(image, 0);
    @memcpy(image[0..4], std.elf.MAGIC);
    image[std.elf.EI_CLASS] = std.elf.ELFCLASS32;
    image[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    image[std.elf.EI_VERSION] = 1;
    writeInteger(u16, image, 16, @intFromEnum(std.elf.ET.EXEC));
    writeInteger(u16, image, 18, @intFromEnum(std.elf.EM.@"386"));
    writeInteger(u32, image, 20, 1);
    writeInteger(u32, image, 24, entry_point);
    writeInteger(u32, image, 28, header_size);
    writeInteger(u16, image, 40, header_size);
    writeInteger(u16, image, 42, program_header_size);
    writeInteger(u16, image, 44, @intCast(segments.len));

    for (segments, 0..) |segment, index| {
        setElf32ProgramHeader(image, index, segment);
    }
}

fn setElf32ProgramHeader(image: []u8, index: usize, segment: Segment) void {
    const offset = @sizeOf(std.elf.Elf32_Ehdr) + index * @sizeOf(std.elf.Elf32_Phdr);
    writeInteger(u32, image, offset, std.elf.PT_LOAD);
    writeInteger(u32, image, offset + 4, segment.file_offset);
    writeInteger(u32, image, offset + 8, segment.virtual_address);
    writeInteger(u32, image, offset + 16, segment.file_size);
    writeInteger(u32, image, offset + 20, segment.memory_size);
    writeInteger(u32, image, offset + 24, segment.flags);
}

fn writeInteger(comptime T: type, image: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, image[offset..][0..@sizeOf(T)], value, .little);
}
