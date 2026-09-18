const std = @import("std");

const architecture_test_kernel = @import("architecture_test_kernel.zig");
const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const qemu_test_runner = @import("qemu_test_runner.zig");
const manifest = @import("../tests/architecture/manifest.zig");

pub fn addStep(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    timeout_seconds: u32,
) void {
    const architecture_tests = build.step(
        "architecture-tests",
        "Run physical architecture tests under QEMU",
    );
    addTestRun(
        build,
        architecture_tests,
        build_configuration,
        timeout_seconds,
        .shared_machine,
        null,
    );
    for (manifest.tests) |test_case| {
        if (!test_case.supports(manifestArchitecture(build_configuration.architecture))) continue;
        if (test_case.mode == .shared_machine) continue;
        addTestRun(
            build,
            architecture_tests,
            build_configuration,
            timeout_seconds,
            test_case.mode,
            test_case,
        );
    }
}

fn addTestRun(
    build: *std.Build,
    architecture_tests: *std.Build.Step,
    build_configuration: configuration.BuildConfig,
    timeout_seconds: u32,
    execution_mode: manifest.ExecutionMode,
    selected_test: ?manifest.Test,
) void {
    const test_id = if (selected_test) |test_case| @tagName(test_case.id) else "shared";
    const test_kernel = architecture_test_kernel.addKernel(build, build_configuration, .{
        .executable_name = build.fmt("architecture-tests-{s}.elf", .{test_id}),
        .entry_point_source = "tests/architecture/main.zig",
        .optimization = .Debug,
        .execution_mode = @tagName(execution_mode),
        .selected_test_id = if (selected_test) |test_case| @tagName(test_case.id) else "",
    });
    const test_disk_image = packageTestDiskImage(
        build,
        build_configuration,
        test_kernel.getEmittedBin(),
        test_id,
    );
    const test_run = qemu_test_runner.addRun(build, .{
        .architecture = build_configuration.architecture,
        .disk_image = test_disk_image,
        .timeout_seconds = timeout_seconds,
        .execution_mode = @tagName(execution_mode),
        .selected_test_id = if (selected_test) |test_case| @tagName(test_case.id) else null,
        .expected_fault = if (selected_test) |test_case| test_case.expected_fault else null,
    });
    architecture_tests.dependOn(&test_run.command.step);
}

fn packageTestDiskImage(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    test_kernel: std.Build.LazyPath,
    test_id: []const u8,
) qemu_test_runner.DiskImage {
    return switch (build_configuration.architecture) {
        .x86_32 => .{
            .kind = .direct_kernel,
            .path = test_kernel,
        },
        .x86_64 => .{
            .kind = .optical_disc,
            .path = limine.createIso(
                build,
                test_kernel,
                build.path("tests/architecture/limine/x86_64.conf"),
                null,
                build.fmt("architecture-tests-x86_64-{s}.iso", .{test_id}),
            ),
        },
    };
}

fn manifestArchitecture(architecture: configuration.Architecture) manifest.Architecture {
    return switch (architecture) {
        .x86_32 => .x86_32,
        .x86_64 => .x86_64,
    };
}
