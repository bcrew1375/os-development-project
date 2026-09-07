const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const abi = b.createModule(.{
        .root_source_file = b.path("src/abi/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shared = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("abi", abi);
    tests.root_module.addImport("shared", shared);

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    const tests_step = b.step("tests", "Run shared ABI and library tests");
    tests_step.dependOn(&run_tests.step);
}
