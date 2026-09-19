const std = @import("std");

const architecture_coverage_kernel = @import("architecture_coverage_kernel.zig");
const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const qemu_test_runner = @import("qemu_test_runner.zig");

pub fn add(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    timeout_seconds: u32,
    kernel_artifacts: architecture_coverage_kernel.Artifacts,
) *std.Build.Step.Run {
    const coverage_frame = runInstrumentedKernel(
        build,
        build_configuration,
        timeout_seconds,
        kernel_artifacts.instrumented_kernel_elf,
    );
    const source_points = collectSourcePoints(
        build,
        kernel_artifacts,
        coverage_frame,
    );
    return createReporter(
        build,
        build_configuration.architecture,
        source_points,
    );
}

fn runInstrumentedKernel(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    timeout_seconds: u32,
    instrumented_kernel_elf: std.Build.LazyPath,
) std.Build.LazyPath {
    const coverage_run = qemu_test_runner.addRun(build, .{
        .architecture = build_configuration.architecture,
        .disk_image = packageDiskImage(
            build,
            build_configuration,
            instrumented_kernel_elf,
        ),
        .timeout_seconds = timeout_seconds,
        .coverage_capture = .enabled,
    });
    return coverage_run.coverage_frame.?;
}

fn packageDiskImage(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    instrumented_kernel_elf: std.Build.LazyPath,
) qemu_test_runner.DiskImage {
    return switch (build_configuration.architecture) {
        .x86_32 => .{
            .kind = .direct_kernel,
            .path = instrumented_kernel_elf,
        },
        .x86_64 => .{
            .kind = .optical_disc,
            .path = limine.createIso(
                build,
                instrumented_kernel_elf,
                build.path("tests/architecture/limine/x86_64.conf"),
                &.{},
                "architecture-coverage-x86_64.iso",
            ),
        },
    };
}

fn collectSourcePoints(
    build: *std.Build,
    kernel_artifacts: architecture_coverage_kernel.Artifacts,
    coverage_frame: std.Build.LazyPath,
) std.Build.LazyPath {
    const collector = build.addSystemCommand(&.{"python3"});
    collector.addFileArg(build.path("tools/architecture_coverage/collect.py"));
    collector.addFileArg(kernel_artifacts.original_llvm_ir);
    collector.addFileArg(kernel_artifacts.instrumented_kernel_elf);
    collector.addFileArg(coverage_frame);
    return collector.addOutputFileArg("architecture-coverage.points");
}

fn createReporter(
    build: *std.Build,
    architecture: configuration.Architecture,
    source_points: std.Build.LazyPath,
) *std.Build.Step.Run {
    const coverage_report_module = build.createModule(.{
        .root_source_file = build.path("tools/coverage/report/main.zig"),
        .target = build.graph.host,
        .optimize = .Debug,
    });
    const reporter = build.addExecutable(.{
        .name = "architecture-coverage-report",
        .root_module = build.createModule(.{
            .root_source_file = build.path("tools/architecture_coverage/main.zig"),
            .target = build.graph.host,
            .optimize = .Debug,
        }),
    });
    const coverage_points_file_module = build.createModule(.{
        .root_source_file = build.path("tools/architecture_coverage/points_file.zig"),
        .target = build.graph.host,
        .optimize = .Debug,
    });
    coverage_points_file_module.addImport("coverage_report", coverage_report_module);
    reporter.root_module.addImport("coverage_report", coverage_report_module);
    reporter.root_module.addImport("coverage_points_file", coverage_points_file_module);

    const run_reporter = build.addRunArtifact(reporter);
    run_reporter.addFileArg(source_points);
    run_reporter.addArg(build.pathFromRoot("."));
    run_reporter.addArg(@tagName(architecture));
    run_reporter.has_side_effects = true;
    return run_reporter;
}
