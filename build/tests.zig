const std = @import("std");

const modules = @import("modules.zig");

pub fn addStep(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const tests_step = b.step("tests", "Run all monorepo unit tests");

    addKernelTests(b, optimize, tests_step);
    const coverage_tool_tests = b.addSystemCommand(&.{"python3"});
    coverage_tool_tests.addFileArg(b.path("tests/architecture_coverage_tests.py"));
    tests_step.dependOn(&coverage_tool_tests.step);
    addComponentTests(b, tests_step, "components/os-abi-library");
    addComponentTests(b, tests_step, "components/os-root-task");
}

pub fn addCoverageStep(b: *std.Build) void {
    const coverage_step = b.step("coverage", "Measure line coverage of common kernel code");
    const common_modules = modules.createCommonModules(b, b.graph.host, .Debug, false);
    const coverage_report = b.createModule(.{
        .root_source_file = b.path("tools/coverage/report.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const tests = b.addTest(.{
        .name = "coverage-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .code_model = .normal,
            .fuzz = true,
        }),
        .test_runner = .{
            .path = b.path("tools/coverage/main.zig"),
            .mode = .simple,
        },
        .use_llvm = true,
        .use_lld = true,
    });

    common_modules.arch.fuzz = true;
    common_modules.kernel_common.fuzz = true;
    modules.addCommonImports(tests.root_module, common_modules);
    tests.root_module.addImport("coverage_report", coverage_report);
    tests.root_module.error_tracing = true;

    const run_coverage = b.addRunArtifact(tests);
    run_coverage.setCwd(b.path("."));
    run_coverage.addArg(b.pathFromRoot("src/common"));
    run_coverage.has_side_effects = true;
    coverage_step.dependOn(&run_coverage.step);
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
    tests.root_module.addImport("coverage_report", b.createModule(.{
        .root_source_file = b.path("tools/coverage/report.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
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
