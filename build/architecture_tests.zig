const std = @import("std");

const architecture_test_kernel = @import("architecture_test_kernel.zig");
const boot_module_fixtures = @import("boot_module_fixtures.zig");
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
    const fixtures = if (selected_test) |test_case|
        if (test_case.id == .boot_modules_are_cached_reserved_and_capacity_limited)
            boot_module_fixtures.create(build)
        else
            null
    else
        null;
    const test_disk_image = packageTestDiskImage(
        build,
        build_configuration,
        test_kernel.getEmittedBin(),
        test_id,
        fixtures,
    );
    const test_run = qemu_test_runner.addRun(build, .{
        .architecture = build_configuration.architecture,
        .disk_image = test_disk_image,
        .timeout_seconds = timeout_seconds,
        .execution_mode = @tagName(execution_mode),
        .selected_test_id = if (selected_test) |test_case| @tagName(test_case.id) else null,
        .expected_fault = if (selected_test) |test_case| test_case.expected_fault else null,
        .boot_modules = if (build_configuration.architecture == .x86_32)
            if (fixtures) |boot_modules| boot_modules.paths else &.{}
        else
            &.{},
    });
    architecture_tests.dependOn(&test_run.command.step);
}

fn packageTestDiskImage(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    test_kernel: std.Build.LazyPath,
    test_id: []const u8,
    fixtures: ?boot_module_fixtures.Fixtures,
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
                if (fixtures) |boot_modules|
                    boot_module_fixtures.createLimineConfig(build, boot_modules)
                else
                    build.path("tests/architecture/limine/x86_64.conf"),
                createLimineBootModules(build, fixtures),
                build.fmt("architecture-tests-x86_64-{s}.iso", .{test_id}),
            ),
        },
    };
}

fn createLimineBootModules(
    build: *std.Build,
    fixtures: ?boot_module_fixtures.Fixtures,
) []const limine.BootModule {
    const boot_modules = fixtures orelse return &.{};
    const modules = build.allocator.alloc(
        limine.BootModule,
        boot_modules.paths.len,
    ) catch @panic("OOM");
    for (modules, boot_modules.paths, boot_modules.names) |*module, path, name| {
        module.* = .{
            .source = path,
            .iso_name = name,
        };
    }
    return modules;
}

fn manifestArchitecture(architecture: configuration.Architecture) manifest.Architecture {
    return switch (architecture) {
        .x86_32 => .x86_32,
        .x86_64 => .x86_64,
    };
}
