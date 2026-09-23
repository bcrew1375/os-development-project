const kernelSetup = @import("../main.zig").kernelSetup;
const build_options = @import("build_options");

comptime {
    if (build_options.x86_32_multiboot) {
        @export(&_start, .{ .name = "_start" });
    }
}

// OS Dev: https://wiki.osdev.org/Zig_Bare_Bones
const MB_HEADER_MAGIC = 0x1BADB002;
const MB_FLAG_ALIGN = 1 << 0;
const MB_FLAG_MEMINFO = 1 << 1;
const MB_FLAG_VIDEO_MODE = 1 << 2;
const FLAGS = MB_FLAG_ALIGN | MB_FLAG_MEMINFO | MB_FLAG_VIDEO_MODE;

const MultibootHeader = extern struct {
    magic: u32 = MB_HEADER_MAGIC,
    flags: u32 = FLAGS,
    checksum: u32,
    mode_type: u32 = 0,
    width: u32 = 640,
    height: u32 = 400,
    depth: u32 = 32,
};

pub export var multiboot_header: MultibootHeader align(32) linksection(".multiboot.header") = .{
    // Here we are adding magic and flags and ~ to get 1's complement and by adding 1 we get 2's complement
    .checksum = ~@as(u32, (MB_HEADER_MAGIC + FLAGS)) + 1,
};
// OS Dev: https://wiki.osdev.org/Zig_Bare_Bones

pub const MultibootTable = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline_ptr: u32,
    mods_count: u32,
    mods_addr: u32,
    syms_0: u32,
    syms_1: u32,
    syms_2: u32,
    syms_3: u32,
    mmap_length: u32,
    mmap_addr: u32,
    drives_length: u32,
    drives_addr: u32,
    config_table: u32,
    boot_loader_name: u32,
    apm_table: u32,
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
    framebuffer_addr_low: u32,
    framebuffer_addr_high: u32,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,
    color_info: [6]u8,
};

pub var multibootTable: *MultibootTable linksection(".multiboot.rodata") = undefined;

var startupStack: [16 * 1024]u8 align(16) linksection(".multiboot.bss") = undefined;

pub fn framebufferPhysicalAddress() linksection(".multiboot.text") ?usize {
    const MULTIBOOT_FLAG_FRAMEBUFFER = 1 << 12;

    if ((multibootTable.flags & MULTIBOOT_FLAG_FRAMEBUFFER) == 0) {
        return null;
    }

    const address = (@as(u64, multibootTable.framebuffer_addr_high) << 32) | multibootTable.framebuffer_addr_low;
    if (address > @as(u64, 0xFFFF_FFFF)) {
        return null;
    }

    return @intCast(address);
}

pub fn framebufferByteSize() linksection(".multiboot.text") ?usize {
    const pitch: usize = @intCast(multibootTable.framebuffer_pitch);
    const height: usize = @intCast(multibootTable.framebuffer_height);
    if (pitch == 0 or height == 0) {
        return null;
    }

    const maximum_usize = ~@as(usize, 0);
    if (pitch > maximum_usize / height) {
        return null;
    }

    return pitch * height;
}

pub fn _start() linksection(".multiboot.text") callconv(.naked) noreturn {
    @disableInstrumentation();
    asm volatile (
        \\cli
        \\movl %ebx, (%[multibootTable:P])
        \\mov %[startupStack], %esp
        \\jmp %[kernelSetup:P]
        :
        : [multibootTable] "i" (&multibootTable),
          [kernelSetup] "i" (&kernelSetup),
          [startupStack] "i" (@as([*]u8, &startupStack) + startupStack.len),
    );
}
