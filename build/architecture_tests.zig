const std = @import("std");

const architecture_test_kernel = @import("architecture_test_kernel.zig");
const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const qemu_test_runner = @import("qemu_test_runner.zig");

pub fn addStep(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    timeout_seconds: u32,
) void {
    const architecture_tests = build.step(
        "architecture-tests",
        "Run physical architecture tests under QEMU",
    );
    const test_kernel = architecture_test_kernel.addKernel(build, build_configuration, .{
        .executable_name = "architecture-tests.elf",
        .entry_point_source = "tests/architecture/main.zig",
        .optimization = .Debug,
    });
    const test_disk_image = packageTestDiskImage(
        build,
        build_configuration,
        test_kernel.getEmittedBin(),
    );
    const test_run = qemu_test_runner.addRun(build, .{
        .architecture = build_configuration.architecture,
        .disk_image = test_disk_image,
        .timeout_seconds = timeout_seconds,
    });
    architecture_tests.dependOn(&test_run.command.step);
}

fn packageTestDiskImage(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    test_kernel: std.Build.LazyPath,
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
                "architecture-tests-x86_64.iso",
            ),
        },
    };
}
