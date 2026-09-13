//! ELF executable parsing support for boot and process-loading paths.

const std = @import("std");

/// Errors reported while validating or interpreting an ELF image.
pub const ElfLoadError = error{
    InvalidElfImage,
    UnsupportedElfClass,
    UnsupportedElfEndian,
    UnsupportedElfVersion,
    UnsupportedElfType,
    UnsupportedElfMachine,
    InvalidProgramHeaderTable,
    InvalidLoadSegment,
    EmptyLoadSegment,
    NoLoadableSegments,
};

const ELF_PROGRAM_HEADER_EXECUTABLE: u32 = 1;
const ELF_PROGRAM_HEADER_WRITABLE: u32 = 2;
const ELF_PROGRAM_HEADER_READABLE: u32 = 4;

/// Access permissions requested by an ELF loadable segment.
pub const SegmentPermissions = struct {
    readable: bool,
    writeable: bool,
    executable: bool,
};

/// Description of a single validated `PT_LOAD` segment.
pub const LoadableSegment = struct {
    virtual_address: u64,
    memory_size: u64,
    file_offset: usize,
    file_size: usize,
    permissions: SegmentPermissions,
};

/// Summary of the loadable portion of an executable image.
pub const LoadableImage = struct {
    entry_point: u64,
    virtual_start: u64,
    virtual_end: u64,
    segment_count: usize,
};

const ElfHeader = struct {
    class: u8,
    entry_point: u64,
    program_header_offset: u64,
    program_header_entry_size: u16,
    program_header_count: u16,
};

const ProgramHeader = struct {
    p_type: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_flags: u32,
};

/// Validates `image` and returns aggregate load information for all loadable segments.
pub fn parseLoadableImage(image: []const u8, page_size: u64) ElfLoadError!LoadableImage {
    const elf_header = try readElfHeader(image);
    try validateElfHeader(elf_header);

    var image_start: u64 = std.math.maxInt(u64);
    var image_end: u64 = 0;
    var loadable_segment_count: usize = 0;

    for (0..elf_header.program_header_count) |program_header_index| {
        const program_header = try readProgramHeader(image, elf_header, program_header_index);
        if (program_header.p_type != std.elf.PT_LOAD) {
            continue;
        }

        try validateLoadableProgramHeader(image, program_header);

        const virtual_start = @as(u64, program_header.p_vaddr);
        const virtual_end = std.math.add(u64, virtual_start, program_header.p_memsz) catch return ElfLoadError.InvalidLoadSegment;

        image_start = @min(image_start, std.mem.alignBackward(u64, virtual_start, page_size));
        image_end = @max(image_end, std.mem.alignForward(u64, virtual_end, page_size));
        loadable_segment_count += 1;
    }

    if (loadable_segment_count == 0) return ElfLoadError.NoLoadableSegments;
    if (image_start >= image_end) return ElfLoadError.InvalidLoadSegment;

    return .{
        .entry_point = elf_header.entry_point,
        .virtual_start = image_start,
        .virtual_end = image_end,
        .segment_count = loadable_segment_count,
    };
}

/// Returns the `loadable_segment_index`th validated loadable segment.
pub fn getLoadableSegment(image: []const u8, loadable_segment_index: usize) ElfLoadError!LoadableSegment {
    const elf_header = try readElfHeader(image);
    try validateElfHeader(elf_header);

    var current_loadable_index: usize = 0;
    for (0..elf_header.program_header_count) |program_header_index| {
        const program_header = try readProgramHeader(image, elf_header, program_header_index);
        if (program_header.p_type != std.elf.PT_LOAD) {
            continue;
        }

        if (current_loadable_index == loadable_segment_index) {
            try validateLoadableProgramHeader(image, program_header);
            return loadableSegmentFromProgramHeader(program_header);
        }

        current_loadable_index += 1;
    }

    return ElfLoadError.InvalidLoadSegment;
}

fn validateElfHeader(elf_header: ElfHeader) ElfLoadError!void {
    if (elf_header.program_header_count == 0) return ElfLoadError.InvalidProgramHeaderTable;
}

fn readElfHeader(image: []const u8) ElfLoadError!ElfHeader {
    if (image.len < @sizeOf(std.elf.Elf32_Ehdr)) return ElfLoadError.InvalidElfImage;

    const ident = image[0..std.elf.EI_NIDENT];
    if (!std.mem.eql(u8, ident[0..4], std.elf.MAGIC)) return ElfLoadError.InvalidElfImage;
    if (ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return ElfLoadError.UnsupportedElfEndian;
    if (ident[std.elf.EI_VERSION] != 1) return ElfLoadError.UnsupportedElfVersion;

    return switch (ident[std.elf.EI_CLASS]) {
        std.elf.ELFCLASS32 => readElf32Header(image),
        std.elf.ELFCLASS64 => readElf64Header(image),
        else => ElfLoadError.UnsupportedElfClass,
    };
}

fn readElf32Header(image: []const u8) ElfLoadError!ElfHeader {
    if (image.len < @sizeOf(std.elf.Elf32_Ehdr)) return ElfLoadError.InvalidElfImage;

    const elf_header = std.mem.bytesToValue(std.elf.Elf32_Ehdr, image[0..@sizeOf(std.elf.Elf32_Ehdr)]);
    if (elf_header.e_type != std.elf.ET.EXEC) return ElfLoadError.UnsupportedElfType;
    if (elf_header.e_machine != std.elf.EM.@"386") return ElfLoadError.UnsupportedElfMachine;
    if (elf_header.e_phentsize != @sizeOf(std.elf.Elf32_Phdr)) return ElfLoadError.InvalidProgramHeaderTable;

    return .{
        .class = std.elf.ELFCLASS32,
        .entry_point = elf_header.e_entry,
        .program_header_offset = elf_header.e_phoff,
        .program_header_entry_size = elf_header.e_phentsize,
        .program_header_count = elf_header.e_phnum,
    };
}

fn readElf64Header(image: []const u8) ElfLoadError!ElfHeader {
    if (image.len < @sizeOf(std.elf.Elf64_Ehdr)) return ElfLoadError.InvalidElfImage;

    const elf_header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, image[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    if (elf_header.e_type != std.elf.ET.EXEC) return ElfLoadError.UnsupportedElfType;
    if (elf_header.e_machine != std.elf.EM.X86_64) return ElfLoadError.UnsupportedElfMachine;
    if (elf_header.e_phentsize != @sizeOf(std.elf.Elf64_Phdr)) return ElfLoadError.InvalidProgramHeaderTable;

    return .{
        .class = std.elf.ELFCLASS64,
        .entry_point = elf_header.e_entry,
        .program_header_offset = elf_header.e_phoff,
        .program_header_entry_size = elf_header.e_phentsize,
        .program_header_count = elf_header.e_phnum,
    };
}

fn readProgramHeader(image: []const u8, elf_header: ElfHeader, program_header_index: usize) ElfLoadError!ProgramHeader {
    if (program_header_index >= elf_header.program_header_count) return ElfLoadError.InvalidProgramHeaderTable;

    const program_header_offset: usize = @intCast(elf_header.program_header_offset);
    const program_header_entry_size: usize = @intCast(elf_header.program_header_entry_size);
    const program_header_table_size = std.math.mul(usize, @as(usize, elf_header.program_header_count), program_header_entry_size) catch return ElfLoadError.InvalidProgramHeaderTable;
    const program_header_table_end = std.math.add(usize, program_header_offset, program_header_table_size) catch return ElfLoadError.InvalidProgramHeaderTable;
    if (program_header_table_end > image.len) return ElfLoadError.InvalidProgramHeaderTable;

    const current_program_header_offset = program_header_offset + program_header_index * program_header_entry_size;
    return switch (elf_header.class) {
        std.elf.ELFCLASS32 => programHeaderFromElf32(std.mem.bytesToValue(std.elf.Elf32_Phdr, image[current_program_header_offset..][0..@sizeOf(std.elf.Elf32_Phdr)])),
        std.elf.ELFCLASS64 => programHeaderFromElf64(std.mem.bytesToValue(std.elf.Elf64_Phdr, image[current_program_header_offset..][0..@sizeOf(std.elf.Elf64_Phdr)])),
        else => ElfLoadError.UnsupportedElfClass,
    };
}

fn programHeaderFromElf32(program_header: std.elf.Elf32_Phdr) ProgramHeader {
    return .{
        .p_type = program_header.p_type,
        .p_offset = program_header.p_offset,
        .p_vaddr = program_header.p_vaddr,
        .p_filesz = program_header.p_filesz,
        .p_memsz = program_header.p_memsz,
        .p_flags = program_header.p_flags,
    };
}

fn programHeaderFromElf64(program_header: std.elf.Elf64_Phdr) ProgramHeader {
    return .{
        .p_type = program_header.p_type,
        .p_offset = program_header.p_offset,
        .p_vaddr = program_header.p_vaddr,
        .p_filesz = program_header.p_filesz,
        .p_memsz = program_header.p_memsz,
        .p_flags = program_header.p_flags,
    };
}

fn validateLoadableProgramHeader(image: []const u8, program_header: ProgramHeader) ElfLoadError!void {
    if (program_header.p_memsz == 0) return ElfLoadError.EmptyLoadSegment;
    if (program_header.p_filesz > program_header.p_memsz) return ElfLoadError.InvalidLoadSegment;

    const file_offset: usize = @intCast(program_header.p_offset);
    const file_size: usize = @intCast(program_header.p_filesz);
    const file_end = std.math.add(usize, file_offset, file_size) catch return ElfLoadError.InvalidLoadSegment;
    if (file_end > image.len) return ElfLoadError.InvalidLoadSegment;
}

fn loadableSegmentFromProgramHeader(program_header: ProgramHeader) LoadableSegment {
    return .{
        .virtual_address = program_header.p_vaddr,
        .memory_size = program_header.p_memsz,
        .file_offset = @intCast(program_header.p_offset),
        .file_size = @intCast(program_header.p_filesz),
        .permissions = .{
            .readable = (program_header.p_flags & ELF_PROGRAM_HEADER_READABLE) != 0,
            .writeable = (program_header.p_flags & ELF_PROGRAM_HEADER_WRITABLE) != 0,
            .executable = (program_header.p_flags & ELF_PROGRAM_HEADER_EXECUTABLE) != 0,
        },
    };
}
