const std = @import("std");

const Architecture = enum {
    x86_32,
    x86_64,
};

const BuildConfig = struct {
    architecture: Architecture,
    target: std.Build.ResolvedTarget,
    linker_script: []const u8,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const architecture = b.option(
        Architecture,
        "arch",
        "Target architecture",
    ) orelse .x86_64;

    const config = resolveConfig(b, architecture);
    addRootTask(b, config, optimize);
    addTests(b, optimize);
}

fn resolveConfig(b: *std.Build, architecture: Architecture) BuildConfig {
    return switch (architecture) {
        .x86_32 => .{
            .architecture = architecture,
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .none,
            }),
            .linker_script = "src/linker_x86_32.ld",
        },
        .x86_64 => .{
            .architecture = architecture,
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
            }),
            .linker_script = "src/linker_x86_64.ld",
        },
    };
}

fn addRootTask(
    b: *std.Build,
    config: BuildConfig,
    optimize: std.builtin.OptimizeMode,
) void {
    const abi = createAbiModule(b, config.target, optimize);

    const root_task = b.addExecutable(.{
        .name = "root_process.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = config.target,
            .optimize = optimize,
            .code_model = .normal,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    root_task.root_module.addImport("abi", abi);
    root_task.setLinkerScript(b.path(config.linker_script));

    const install_root_task = b.addInstallArtifact(root_task, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{@tagName(config.architecture)}) } },
    });
    b.getInstallStep().dependOn(&install_root_task.step);
}

fn addTests(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const abi = createAbiModule(b, b.graph.host, optimize);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("abi", abi);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    const tests_step = b.step("tests", "Run root task tests");
    tests_step.dependOn(&run_tests.step);
}

fn createAbiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathFromRoot("../OS-ABI-Library/src/abi/main.zig") },
        .target = target,
        .optimize = optimize,
    });
}
