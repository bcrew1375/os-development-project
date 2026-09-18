const builtin = @import("builtin");

pub const magic = "OSCV0001";
pub const version: u16 = 1;
pub const max_points = 65_536;

pub const Architecture = enum(u8) {
    x86_32 = 1,
    x86_64 = 2,

    pub fn current() Architecture {
        return switch (builtin.cpu.arch) {
            .x86 => .x86_32,
            .x86_64 => .x86_64,
            else => @compileError("unsupported coverage architecture"),
        };
    }
};

pub const Header = extern struct {
    magic: [8]u8 = magic.*,
    version: u16 = version,
    architecture: Architecture,
    pointer_width: u8 = @sizeOf(usize),
    instrumentation_point_count: u32,
    covered_points_bitmap_size: u32,
};
