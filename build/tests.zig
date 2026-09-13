const std = @import("std");

const modules = @import("modules.zig");

pub fn addStep(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const tests_step = b.step("tests", "Run all monorepo unit tests");

    addKernelTests(b, optimize, tests_step);
    addComponentTests(b, tests_step, "components/os-abi-library");
    addComponentTests(b, tests_step, "components/os-root-task");
}

fn addKernelTests(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    tests_step: *std.Build.Step,
) void {
    const common_modules = modules.createCommonModules(b, b.graph.host, optimize, false);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .code_model = .normal,
        }),
    });

    modules.addCommonImports(tests.root_module, common_modules);
    tests.root_module.error_tracing = true;

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    tests_step.dependOn(&run_tests.step);
}

fn addComponentTests(
    b: *std.Build,
    tests_step: *std.Build.Step,
    component_path: []const u8,
) void {
    const script =
        \\set -eu
        \\component_path="$1"
        \\zig_exe="$2"
        \\cd "$component_path"
        \\"$zig_exe" build tests
    ;

    const run_tests = b.addSystemCommand(&.{ "bash", "-c", script, "test-component" });
    run_tests.addArg(component_path);
    run_tests.addArg(b.graph.zig_exe);
    tests_step.dependOn(&run_tests.step);
}
