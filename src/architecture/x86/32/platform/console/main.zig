const TextColor = @import("arch").TextColor;
const multiboot = @import("../../boot/multiboot/main.zig");
const mmu_common = @import("../../mmu/common.zig");
const serial = @import("../../../common/platform/io/serial.zig");
const vga_font = @import("vga_font");

const std = @import("std");

const LEGACY_TEXT_MODE_WIDTH: usize = 80;
const LEGACY_TEXT_MODE_HEIGHT: usize = 25;
const LEGACY_TEXT_MODE_BUFFER_SIZE = LEGACY_TEXT_MODE_WIDTH * LEGACY_TEXT_MODE_HEIGHT;
const LEGACY_TEXT_MODE_BUFFER_ADDRESS = 0xC00B8000;
const MULTIBOOT_FLAG_FRAMEBUFFER = 1 << 12;
const MULTIBOOT_FRAMEBUFFER_TYPE_RGB = 1;

const DEFAULT_TEXT_MODE_WIDTH: usize = LEGACY_TEXT_MODE_WIDTH;
const DEFAULT_TEXT_MODE_HEIGHT: usize = LEGACY_TEXT_MODE_HEIGHT;
const MAX_TEXT_MODE_WIDTH: usize = 160;
const MAX_TEXT_MODE_HEIGHT: usize = 75;
const TEXT_MODE_BUFFER_SIZE = MAX_TEXT_MODE_WIDTH * MAX_TEXT_MODE_HEIGHT;

const GLYPH_WIDTH = vga_font.GLYPH_WIDTH;
const GLYPH_HEIGHT = vga_font.GLYPH_HEIGHT;

const legacy_text_buffer: *volatile [LEGACY_TEXT_MODE_BUFFER_SIZE]u16 = @ptrFromInt(LEGACY_TEXT_MODE_BUFFER_ADDRESS);

const Cell = struct {
    character: u8,
    foreground: VGAColor,
    background: VGAColor,
};

const FramebufferConsole = struct {
    framebuffer: *allowzero anyopaque,
    width: usize,
    height: usize,
    pitch: usize,
    bytes_per_pixel: usize,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    columns: usize,
    rows: usize,
};

const VGAColor = enum(u4) {
    BLACK,
    BLUE,
    GREEN,
    CYAN,
    RED,
    MAGENTA,
    BROWN,
    LIGHT_GRAY,
    DARK_GRAY,
    LIGHT_BLUE,
    LIGHT_GREEN,
    LIGHT_CYAN,
    LIGHT_RED,
    LIGHT_MAGENTA,
    YELLOW,
    WHITE,
};

const RGBColor = struct {
    red: u8,
    green: u8,
    blue: u8,
};

const VGA_PALETTE = [_]RGBColor{
    .{ .red = 0x00, .green = 0x00, .blue = 0x00 },
    .{ .red = 0x00, .green = 0x00, .blue = 0xAA },
    .{ .red = 0x00, .green = 0xAA, .blue = 0x00 },
    .{ .red = 0x00, .green = 0xAA, .blue = 0xAA },
    .{ .red = 0xAA, .green = 0x00, .blue = 0x00 },
    .{ .red = 0xAA, .green = 0x00, .blue = 0xAA },
    .{ .red = 0xAA, .green = 0x55, .blue = 0x00 },
    .{ .red = 0xAA, .green = 0xAA, .blue = 0xAA },
    .{ .red = 0x55, .green = 0x55, .blue = 0x55 },
    .{ .red = 0x55, .green = 0x55, .blue = 0xFF },
    .{ .red = 0x55, .green = 0xFF, .blue = 0x55 },
    .{ .red = 0x55, .green = 0xFF, .blue = 0xFF },
    .{ .red = 0xFF, .green = 0x55, .blue = 0x55 },
    .{ .red = 0xFF, .green = 0x55, .blue = 0xFF },
    .{ .red = 0xFF, .green = 0xFF, .blue = 0x55 },
    .{ .red = 0xFF, .green = 0xFF, .blue = 0xFF },
};

var row: usize = 0;
var column: usize = 0;
var active_columns: usize = DEFAULT_TEXT_MODE_WIDTH;
var active_rows: usize = DEFAULT_TEXT_MODE_HEIGHT;
var active_color: VGAColor = .WHITE;
var framebuffer_console: ?FramebufferConsole = null;
var text_buffer: [TEXT_MODE_BUFFER_SIZE]Cell = undefined;

pub fn initialize() void {
    serial.initialize();

    row = 0;
    column = 0;
    active_columns = DEFAULT_TEXT_MODE_WIDTH;
    active_rows = DEFAULT_TEXT_MODE_HEIGHT;
    active_color = .WHITE;
    initializeTextBuffer();

    framebuffer_console = discoverFramebuffer();
    if (framebuffer_console) |console| {
        active_columns = console.columns;
        active_rows = console.rows;
        clearFramebuffer(console, .BLACK);
        redrawTextBuffer();
    } else {
        clearLegacyTextMode();
    }
}

const Writer = std.Io.Writer;

fn drain(_: *Writer, data: []const []const u8, _: usize) Writer.Error!usize {
    var written: usize = 0;
    for (data) |chunk| {
        print(chunk);
        written += chunk.len;
    }
    return written;
}

const writer_vtable: Writer.VTable = .{ .drain = drain };
var writer_instance: Writer = .{ .vtable = &writer_vtable, .buffer = &.{} };

pub fn writer() *Writer {
    return &writer_instance;
}

pub fn print(string: []const u8) void {
    serial.writeString(string);

    for (string) |character| {
        writeChar(character);
    }
}

pub fn setColor(color: TextColor) void {
    active_color = textColorToVGAColor(color);
}

fn discoverFramebuffer() ?FramebufferConsole {
    if ((multiboot.multibootTable.flags & MULTIBOOT_FLAG_FRAMEBUFFER) == 0) {
        return null;
    }

    if (multiboot.multibootTable.framebuffer_type != MULTIBOOT_FRAMEBUFFER_TYPE_RGB or multiboot.multibootTable.framebuffer_bpp != 32) {
        return null;
    }

    const physical_address = multiboot.framebufferPhysicalAddress() orelse return null;

    const width: usize = @intCast(multiboot.multibootTable.framebuffer_width);
    const height: usize = @intCast(multiboot.multibootTable.framebuffer_height);
    const pitch: usize = @intCast(multiboot.multibootTable.framebuffer_pitch);
    const columns = @min(width / GLYPH_WIDTH, MAX_TEXT_MODE_WIDTH);
    const rows = @min(height / GLYPH_HEIGHT, MAX_TEXT_MODE_HEIGHT);

    if (columns == 0 or rows == 0) {
        return null;
    }

    return .{
        .framebuffer = @ptrFromInt(mmu_common.RESERVED_VIRTUAL_ADDRESS + (physical_address & (mmu_common.PAGE_SIZE - 1))),
        .width = width,
        .height = height,
        .pitch = pitch,
        .bytes_per_pixel = multiboot.multibootTable.framebuffer_bpp / 8,
        .red_mask_shift = multiboot.multibootTable.color_info[0],
        .red_mask_size = multiboot.multibootTable.color_info[1],
        .green_mask_shift = multiboot.multibootTable.color_info[2],
        .green_mask_size = multiboot.multibootTable.color_info[3],
        .blue_mask_shift = multiboot.multibootTable.color_info[4],
        .blue_mask_size = multiboot.multibootTable.color_info[5],
        .columns = columns,
        .rows = rows,
    };
}

fn initializeTextBuffer() void {
    for (&text_buffer) |*cell| {
        cell.* = blankCell(active_color);
    }
}

fn blankCell(foreground: VGAColor) Cell {
    return .{
        .character = ' ',
        .foreground = foreground,
        .background = .BLACK,
    };
}

fn writeChar(character: u8) void {
    switch (character) {
        '\n' => {
            nextLine();
            return;
        },
        '\r' => {
            column = 0;
            return;
        },
        '\t' => {
            const next_tab_column = (column + 8) & ~@as(usize, 7);
            while (column < next_tab_column) {
                writeChar(' ');
            }
            return;
        },
        else => {},
    }

    if (column >= active_columns) {
        nextLine();
    }

    if (row >= active_rows) {
        scrollLine();
    }

    putChar(column, row, character, active_color);
    column += 1;
}

fn putChar(x_position: usize, y_position: usize, character: u8, color: VGAColor) void {
    const cell_index = (y_position * MAX_TEXT_MODE_WIDTH) + x_position;
    text_buffer[cell_index] = .{
        .character = character,
        .foreground = color,
        .background = .BLACK,
    };

    if (framebuffer_console != null) {
        drawCell(x_position, y_position, text_buffer[cell_index]);
    } else {
        putLegacyChar(x_position, y_position, character, color);
    }
}

fn nextLine() void {
    row += 1;
    column = 0;

    if (row >= active_rows) {
        scrollLine();
    }
}

fn scrollLine() void {
    for (1..active_rows) |source_row| {
        for (0..active_columns) |cell_column| {
            text_buffer[((source_row - 1) * MAX_TEXT_MODE_WIDTH) + cell_column] = text_buffer[(source_row * MAX_TEXT_MODE_WIDTH) + cell_column];
        }
    }

    for (0..active_columns) |cell_column| {
        text_buffer[((active_rows - 1) * MAX_TEXT_MODE_WIDTH) + cell_column] = blankCell(active_color);
    }

    row = active_rows - 1;
    redrawTextBuffer();
}

fn redrawTextBuffer() void {
    if (framebuffer_console != null) {
        for (0..active_rows) |cell_y| {
            for (0..active_columns) |cell_x| {
                drawCell(cell_x, cell_y, text_buffer[(cell_y * MAX_TEXT_MODE_WIDTH) + cell_x]);
            }
        }
    } else {
        for (0..active_rows) |cell_y| {
            for (0..active_columns) |cell_x| {
                const cell = text_buffer[(cell_y * MAX_TEXT_MODE_WIDTH) + cell_x];
                putLegacyChar(cell_x, cell_y, cell.character, cell.foreground);
            }
        }
    }
}

fn drawCell(cell_x: usize, cell_y: usize, cell: Cell) void {
    const console = framebuffer_console orelse return;
    const origin_x = cell_x * GLYPH_WIDTH;
    const origin_y = cell_y * GLYPH_HEIGHT;
    const foreground = pixelValue(console, VGA_PALETTE[@intFromEnum(cell.foreground)]);
    const background = pixelValue(console, VGA_PALETTE[@intFromEnum(cell.background)]);

    for (0..GLYPH_HEIGHT) |glyph_y| {
        const glyph_row = vga_font.glyphRow(cell.character, glyph_y);
        for (0..GLYPH_WIDTH) |glyph_x| {
            const mask = @as(u8, 0x80) >> @intCast(glyph_x);
            const pixel = if ((glyph_row & mask) != 0) foreground else background;
            putPixel(console, origin_x + glyph_x, origin_y + glyph_y, pixel);
        }
    }
}

fn clearFramebuffer(console: FramebufferConsole, color: VGAColor) void {
    const pixel = pixelValue(console, VGA_PALETTE[@intFromEnum(color)]);
    for (0..console.height) |y| {
        for (0..console.width) |x| {
            putPixel(console, x, y, pixel);
        }
    }
}

fn putPixel(console: FramebufferConsole, x: usize, y: usize, pixel: u32) void {
    if (x >= console.width or y >= console.height) {
        return;
    }

    const row_address = @intFromPtr(console.framebuffer) + (y * console.pitch);
    const pixel_address = row_address + (x * console.bytes_per_pixel);
    const pixel_pointer: *volatile u32 = @ptrFromInt(pixel_address);
    pixel_pointer.* = pixel;
}

fn pixelValue(console: FramebufferConsole, color: RGBColor) u32 {
    return (scaleColorComponent(color.red, console.red_mask_size) << @as(u5, @intCast(console.red_mask_shift))) |
        (scaleColorComponent(color.green, console.green_mask_size) << @as(u5, @intCast(console.green_mask_shift))) |
        (scaleColorComponent(color.blue, console.blue_mask_size) << @as(u5, @intCast(console.blue_mask_shift)));
}

fn scaleColorComponent(component: u8, mask_size: u8) u32 {
    if (mask_size == 0) {
        return 0;
    }

    if (mask_size >= 8) {
        return @as(u32, component) << @intCast(mask_size - 8);
    }

    return @as(u32, component) >> @intCast(8 - mask_size);
}

fn clearLegacyTextMode() void {
    @memset(legacy_text_buffer[0..LEGACY_TEXT_MODE_BUFFER_SIZE], makeLegacyChar(' ', active_color));
}

fn putLegacyChar(x_position: usize, y_position: usize, character: u8, color: VGAColor) void {
    if (x_position >= LEGACY_TEXT_MODE_WIDTH or y_position >= LEGACY_TEXT_MODE_HEIGHT) {
        return;
    }

    legacy_text_buffer[(y_position * LEGACY_TEXT_MODE_WIDTH) + x_position] = makeLegacyChar(character, color);
}

fn makeLegacyChar(character: u8, color: VGAColor) u16 {
    return (@as(u16, @intFromEnum(color)) << 8) | character;
}

fn textColorToVGAColor(text_color: TextColor) VGAColor {
    return switch (text_color) {
        TextColor.BLACK => VGAColor.BLACK,
        TextColor.BLUE => VGAColor.BLUE,
        TextColor.GREEN => VGAColor.GREEN,
        TextColor.CYAN => VGAColor.CYAN,
        TextColor.RED => VGAColor.RED,
        TextColor.MAGENTA => VGAColor.MAGENTA,
        TextColor.BROWN => VGAColor.BROWN,
        TextColor.LIGHT_GRAY => VGAColor.LIGHT_GRAY,
        TextColor.DARK_GRAY => VGAColor.DARK_GRAY,
        TextColor.LIGHT_BLUE => VGAColor.LIGHT_BLUE,
        TextColor.LIGHT_GREEN => VGAColor.LIGHT_GREEN,
        TextColor.LIGHT_CYAN => VGAColor.LIGHT_CYAN,
        TextColor.LIGHT_RED => VGAColor.LIGHT_RED,
        TextColor.LIGHT_MAGENTA => VGAColor.LIGHT_MAGENTA,
        TextColor.YELLOW => VGAColor.YELLOW,
        TextColor.WHITE => VGAColor.WHITE,
    };
}
