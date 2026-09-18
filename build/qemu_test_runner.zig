const std = @import("std");

const configuration = @import("configuration.zig");

pub const ImageKind = enum {
    direct_kernel,
    optical_disc,

    fn commandLineValue(self: ImageKind) []const u8 {
        return switch (self) {
            .direct_kernel => "kernel",
            .optical_disc => "cdrom",
        };
    }
};

pub const DiskImage = struct {
    kind: ImageKind,
    path: std.Build.LazyPath,
};

pub const CoverageCapture = enum {
    disabled,
    enabled,
};

pub const RunOptions = struct {
    architecture: configuration.Architecture,
    disk_image: DiskImage,
    timeout_seconds: u32,
    coverage_capture: CoverageCapture = .disabled,
};

pub const RunResult = struct {
    command: *std.Build.Step.Run,
    coverage_frame: ?std.Build.LazyPath,
};

pub fn resolveTimeoutSeconds(build: *std.Build) u32 {
    const timeout_seconds = build.option(
        u32,
        "architecture-test-timeout",
        "Maximum QEMU architecture-test runtime in seconds",
    ) orelse 60;
    if (timeout_seconds == 0) {
        std.debug.panic("-Darchitecture-test-timeout must be greater than zero", .{});
    }
    return timeout_seconds;
}

pub fn addRun(build: *std.Build, options: RunOptions) RunResult {
    const command = build.addSystemCommand(&.{"python3"});
    command.addFileArg(build.path("tools/architecture_test_runner.py"));
    command.addArgs(&.{
        "--architecture",
        @tagName(options.architecture),
        "--image-kind",
        options.disk_image.kind.commandLineValue(),
        "--image",
    });
    command.addFileArg(options.disk_image.path);
    command.addArgs(&.{
        "--timeout-seconds",
        build.fmt("{d}", .{options.timeout_seconds}),
    });

    const coverage_frame = switch (options.coverage_capture) {
        .disabled => null,
        .enabled => captureCoverageFrame(command),
    };
    command.has_side_effects = true;
    return .{
        .command = command,
        .coverage_frame = coverage_frame,
    };
}

fn captureCoverageFrame(command: *std.Build.Step.Run) std.Build.LazyPath {
    command.addArg("--coverage-output");
    return command.addOutputFileArg("architecture-coverage.bin");
}
