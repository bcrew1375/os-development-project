const std = @import("std");

pub const CommonModules = struct {
    arch: *std.Build.Module,
    kernel_common: *std.Build.Module,
    shared: *std.Build.Module,
    abi: *std.Build.Module,
    vga_font: *std.Build.Module,
    build_options: *std.Build.Step.Options,
};

pub fn createCommonModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    x86_32_multiboot: bool,
) CommonModules {
    const arch = b.createModule(.{
        .root_source_file = b.path("src/architecture/architecture.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kernel_common = b.createModule(.{
        .root_source_file = b.path("src/kernel_common.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shared = b.createModule(.{
        .root_source_file = b.path("dependencies/os-abi-library/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const abi = b.createModule(.{
        .root_source_file = b.path("dependencies/os-abi-library/src/abi/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vga_font = b.createModule(.{
        .root_source_file = b.path("src/common/terminal/vga_font.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "x86_32_multiboot", x86_32_multiboot);

    arch.addImport("arch", arch);
    arch.addImport("kernel_common", kernel_common);
    arch.addImport("abi", abi);
    arch.addImport("vga_font", vga_font);
    arch.addOptions("build_options", build_options);

    kernel_common.addImport("arch", arch);
    kernel_common.addImport("abi", abi);

    return .{
        .arch = arch,
        .kernel_common = kernel_common,
        .shared = shared,
        .abi = abi,
        .vga_font = vga_font,
        .build_options = build_options,
    };
}

pub fn addCommonImports(root_module: *std.Build.Module, common_modules: CommonModules) void {
    root_module.addImport("arch", common_modules.arch);
    root_module.addImport("kernel_common", common_modules.kernel_common);
    root_module.addImport("shared", common_modules.shared);
    root_module.addImport("abi", common_modules.abi);
}
