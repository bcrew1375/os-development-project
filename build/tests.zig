const std = @import("std");

const modules = @import("modules.zig");

pub fn addStep(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const tests_step = b.step("tests", "Run all monorepo unit tests");

    addKernelTests(b, optimize, tests_step);
    const coverage_tool_tests = b.addSystemCommand(&.{"python3"});
    coverage_tool_tests.addFileArg(b.path("tests/architecture_coverage_tests.py"));
    tests_step.dependOn(&coverage_tool_tests.step);
    const system_smoke_runner_tests = b.addSystemCommand(&.{"python3"});
    system_smoke_runner_tests.addFileArg(b.path("tests/system_smoke_runner_tests.py"));
    tests_step.dependOn(&system_smoke_runner_tests.step);
    const test_trend_report_tests = b.addSystemCommand(&.{"python3"});
    test_trend_report_tests.addFileArg(b.path("tests/test_trend_report_tests.py"));
    tests_step.dependOn(&test_trend_report_tests.step);
    addComponentTests(b, tests_step, "components/os-abi-library");
    addComponentTests(b, tests_step, "components/os-root-task");
}

pub fn addCoverageStep(b: *std.Build) void {
    const coverage_step = b.step("coverage", "Measure line coverage of common kernel code");
    const common_modules = modules.createCommonModules(b, b.graph.host, .Debug, false);
    const coverage_report = b.createModule(.{
        .root_source_file = b.path("tools/coverage/report/main.zig"),
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
        }),
        .test_runner = .{
            .path = b.path("tools/coverage/main.zig"),
            .mode = .simple,
        },
        .use_llvm = true,
        .use_lld = true,
    });
    tests.sanitize_coverage_trace_pc_guard = true;
    tests.bundle_ubsan_rt = false;
    const sanitizer_runtime_module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
    });
    sanitizer_runtime_module.addCSourceFiles(.{
        .files = &.{"tools/coverage/sanitizer_runtime.c"},
        .flags = &.{"-fno-sanitize=undefined"},
    });
    const sanitizer_runtime = b.addObject(.{
        .name = "coverage-sanitizer-runtime",
        .root_module = sanitizer_runtime_module,
    });
    tests.root_module.addObject(sanitizer_runtime);

    modules.addCommonImports(tests.root_module, common_modules);
    addKernelTestImports(b, tests.root_module, common_modules, .Debug);
    tests.root_module.addImport("coverage_report", coverage_report);
    const architecture_points_file = b.createModule(.{
        .root_source_file = b.path("tools/architecture_coverage/points_file.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    architecture_points_file.addImport("coverage_report", coverage_report);
    tests.root_module.addImport("architecture_points_file", architecture_points_file);
    const architecture_coverage_source_manifest = b.createModule(.{
        .root_source_file = b.path("tools/architecture_coverage/source_manifest.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tests.root_module.addImport(
        "architecture_coverage_source_manifest",
        architecture_coverage_source_manifest,
    );
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
    addKernelTestImports(b, tests.root_module, common_modules, optimize);
    const coverage_report = b.createModule(.{
        .root_source_file = b.path("tools/coverage/report/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    tests.root_module.addImport("coverage_report", coverage_report);
    const architecture_points_file = b.createModule(.{
        .root_source_file = b.path("tools/architecture_coverage/points_file.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    architecture_points_file.addImport("coverage_report", coverage_report);
    tests.root_module.addImport("architecture_points_file", architecture_points_file);
    const architecture_coverage_source_manifest = b.createModule(.{
        .root_source_file = b.path("tools/architecture_coverage/source_manifest.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    tests.root_module.addImport(
        "architecture_coverage_source_manifest",
        architecture_coverage_source_manifest,
    );
    tests.root_module.error_tracing = true;

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    tests_step.dependOn(&run_tests.step);
}

fn addKernelTestImports(
    b: *std.Build,
    root_module: *std.Build.Module,
    common_modules: modules.CommonModules,
    optimize: std.builtin.OptimizeMode,
) void {
    const launch_root_process = b.createModule(.{
        .root_source_file = b.path("src/launch_root_process.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    modules.addCommonImports(launch_root_process, common_modules);
    root_module.addImport("launch_root_process", launch_root_process);

    const elf_fixture = b.createModule(.{
        .root_source_file = b.path("components/os-abi-library/tests/elf_fixture.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    root_module.addImport("elf_fixture", elf_fixture);

    const kernel_initialization = b.createModule(.{
        .root_source_file = b.path("src/kernel_initialization.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    root_module.addImport("kernel_initialization", kernel_initialization);
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
