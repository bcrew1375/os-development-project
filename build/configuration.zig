const std = @import("std");

pub const Architecture = enum {
    x86_32,
    x86_64,
};

pub const Bootloader = enum {
    limine,
    multiboot,
};

pub const BuildConfig = struct {
    architecture: Architecture,
    bootloader: Bootloader,
    kernel_target: std.Build.ResolvedTarget,
    kernel_linker_script: []const u8,
    kernel_code_model: std.builtin.CodeModel,
};

pub const RootTaskArtifact = struct {
    path: std.Build.LazyPath,
    install_name: []const u8,
};

const ROOT_TASK_INSTALL_NAME = "root_process.elf";

pub fn resolve(
    b: *std.Build,
    architecture: Architecture,
    requested_bootloader: Bootloader,
) BuildConfig {
    const Target = std.Target.x86;
    const bootloader = switch (architecture) {
        .x86_32 => requested_bootloader,
        .x86_64 => .limine,
    };

    return switch (architecture) {
        .x86_32 => .{
            .architecture = architecture,
            .bootloader = bootloader,
            .kernel_target = b.resolveTargetQuery(.{
                .cpu_arch = .x86,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_features_add = Target.featureSet(&.{.soft_float}),
                .cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx }),
            }),
            .kernel_linker_script = switch (bootloader) {
                .limine => "src/architecture/x86/32/linker_limine.ld",
                .multiboot => "src/architecture/x86/32/linker_multiboot.ld",
            },
            .kernel_code_model = .default,
        },
        .x86_64 => .{
            .architecture = architecture,
            .bootloader = bootloader,
            .kernel_target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                // We use software float because we are disabling all SIMD stuff.
                .cpu_features_add = Target.featureSet(&.{.soft_float}),
                // Disable SIMD in kernel code until context switching saves it.
                .cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx }),
            }),
            .kernel_linker_script = "src/architecture/x86/64/linker.ld",
            .kernel_code_model = .kernel,
        },
    };
}

pub fn resolveRootTaskArtifact(b: *std.Build, config: BuildConfig) RootTaskArtifact {
    if (b.option(
        []const u8,
        "root-task",
        "Path to the externally built root task ELF artifact",
    )) |path| {
        return .{
            .path = .{ .cwd_relative = path },
            .install_name = ROOT_TASK_INSTALL_NAME,
        };
    }

    return .{
        .path = addRootTaskSubmoduleBuild(b, config),
        .install_name = ROOT_TASK_INSTALL_NAME,
    };
}

fn addRootTaskSubmoduleBuild(b: *std.Build, config: BuildConfig) std.Build.LazyPath {
    const script =
        \\set -eu
        \\architecture="$1"
        \\output="$2"
        \\zig_exe="$3"
        \\
        \\cd dependencies/os-root-task
        \\"$zig_exe" build -Darch="$architecture"
        \\mkdir -p "$(dirname "$output")"
        \\cp "zig-out/$architecture/bin/root_process.elf" "$output"
    ;

    const build_root_task = b.addSystemCommand(&.{ "bash", "-c", script, "build-root-task" });
    build_root_task.addArg(@tagName(config.architecture));

    const output = build_root_task.addOutputFileArg(b.fmt(
        "root_process-{s}.elf",
        .{@tagName(config.architecture)},
    ));
    build_root_task.addArg(b.graph.zig_exe);

    return output;
}

pub fn limineConfigPath(architecture: Architecture) []const u8 {
    return switch (architecture) {
        .x86_32 => "src/architecture/x86/32/boot/limine/limine.conf",
        .x86_64 => "src/architecture/x86/64/boot/limine/limine.conf",
    };
}
