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
    const abi_path = b.option(
        []const u8,
        "abi-path",
        "Path to the shared ABI module entry point",
    ) orelse "../os-abi-library/src/abi/main.zig";
    const architecture = b.option(
        Architecture,
        "arch",
        "Target architecture",
    ) orelse .x86_64;

    const config = resolveConfig(b, architecture);
    addRootTask(b, config, optimize, abi_path);
    addTests(b, optimize, abi_path);
}

fn resolveConfig(b: *std.Build, architecture: Architecture) BuildConfig {
    const Target = std.Target.x86;
    return switch (architecture) {
        .x86_32 => .{
            .architecture = architecture,
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = Target.featureSet(&.{.soft_float}),
                .cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx }),
            }),
            .linker_script = "src/linker_x86_32.ld",
        },
        .x86_64 => .{
            .architecture = architecture,
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = Target.featureSet(&.{.soft_float}),
                .cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx }),
            }),
            .linker_script = "src/linker_x86_64.ld",
        },
    };
}

fn addRootTask(
    b: *std.Build,
    config: BuildConfig,
    optimize: std.builtin.OptimizeMode,
    abi_path: []const u8,
) void {
    const abi = createAbiModule(b, config.target, optimize, abi_path);
    const memory_manager = b.createModule(.{
        .root_source_file = b.path("src/memory_manager.zig"),
        .target = config.target,
        .optimize = optimize,
    });
    memory_manager.addImport("abi", abi);
    const bootstrap_memory = b.createModule(.{
        .root_source_file = b.path("src/bootstrap_memory.zig"),
        .target = config.target,
        .optimize = optimize,
    });
    bootstrap_memory.addImport("abi", abi);

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
    root_task.root_module.addImport("bootstrap_memory", bootstrap_memory);
    root_task.root_module.addImport("memory_manager", memory_manager);
    root_task.setLinkerScript(b.path(config.linker_script));

    const install_root_task = b.addInstallArtifact(root_task, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{@tagName(config.architecture)}) } },
    });
    b.getInstallStep().dependOn(&install_root_task.step);
}

fn addTests(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    abi_path: []const u8,
) void {
    const abi = createAbiModule(b, b.graph.host, optimize, abi_path);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("abi", abi);
    const memory_manager = b.createModule(.{
        .root_source_file = b.path("src/memory_manager.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    memory_manager.addImport("abi", abi);
    tests.root_module.addImport("memory_manager", memory_manager);
    const bootstrap_memory = b.createModule(.{
        .root_source_file = b.path("src/bootstrap_memory.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    bootstrap_memory.addImport("abi", abi);
    tests.root_module.addImport("bootstrap_memory", bootstrap_memory);
    const startup = b.createModule(.{
        .root_source_file = b.path("src/startup.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    startup.addImport("abi", abi);
    startup.addImport("bootstrap_memory", bootstrap_memory);
    startup.addImport("memory_manager", memory_manager);
    tests.root_module.addImport("startup", startup);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    const tests_step = b.step("tests", "Run root task tests");
    tests_step.dependOn(&run_tests.step);
}

fn createAbiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    abi_path: []const u8,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathFromRoot(abi_path) },
        .target = target,
        .optimize = optimize,
    });
}
