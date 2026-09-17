const builtin = @import("builtin");
const common = @import("x86/common.zig");
const x86_32 = @import("x86/x86_32.zig");
const x86_64 = @import("x86/x86_64.zig");

pub const architecture_name = switch (builtin.cpu.arch) {
    .x86 => "x86_32",
    .x86_64 => "x86_64",
    else => @compileError("unsupported QEMU test architecture"),
};

pub const tests = common.tests ++ switch (builtin.cpu.arch) {
    .x86 => x86_32.tests,
    .x86_64 => x86_64.tests,
    else => @compileError("unsupported QEMU test architecture"),
};
