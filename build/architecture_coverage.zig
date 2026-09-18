const std = @import("std");

const architecture_coverage_kernel = @import("architecture_coverage_kernel.zig");
const architecture_coverage_report = @import("architecture_coverage_report.zig");
const configuration = @import("configuration.zig");

pub fn addSteps(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    timeout_seconds: u32,
) void {
    const build_kernel_step = build.step(
        "architecture-coverage-kernel",
        "Build an instrumented architecture test kernel",
    );
    const measure_coverage_step = build.step(
        "architecture-coverage",
        "Measure physical architecture coverage under QEMU",
    );

    const kernel_artifacts = architecture_coverage_kernel.add(
        build,
        build_configuration,
    );
    architecture_coverage_kernel.install(
        build,
        build_kernel_step,
        kernel_artifacts,
    );
    const coverage_report = architecture_coverage_report.add(
        build,
        build_configuration,
        timeout_seconds,
        kernel_artifacts,
    );
    measure_coverage_step.dependOn(&coverage_report.step);
}
