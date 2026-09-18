const std = @import("std");

const configuration = @import("configuration.zig");
const modules = @import("modules.zig");

pub const Instrumentation = enum {
    none,
    sanitizer_guards,
};

pub const Options = struct {
    executable_name: []const u8,
    entry_point_source: []const u8,
    optimization: std.builtin.OptimizeMode,
    instrumentation: Instrumentation = .none,
    execution_mode: []const u8 = "shared_machine",
    selected_test_id: []const u8 = "",
};

pub fn addKernel(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    options: Options,
) *std.Build.Step.Compile {
    const common_modules = modules.createCommonModules(
        build,
        build_configuration.kernel_target,
        options.optimization,
        build_configuration.architecture == .x86_32,
    );
    const root_module = build.createModule(.{
        .root_source_file = build.path(options.entry_point_source),
        .target = build_configuration.kernel_target,
        .optimize = options.optimization,
        .code_model = build_configuration.kernel_code_model,
    });
    const kernel = build.addExecutable(.{
        .name = options.executable_name,
        .root_module = root_module,
        .use_llvm = true,
        .use_lld = true,
    });
    modules.addCommonImports(root_module, common_modules);
    const architecture_test_options = build.addOptions();
    architecture_test_options.addOption([]const u8, "execution_mode", options.execution_mode);
    architecture_test_options.addOption([]const u8, "selected_test_id", options.selected_test_id);
    root_module.addOptions("architecture_test_options", architecture_test_options);

    if (options.instrumentation == .sanitizer_guards) {
        const coverage_runtime = build.createModule(.{
            .root_source_file = build.path("tests/architecture/coverage/runtime.zig"),
            .target = build_configuration.kernel_target,
            .optimize = options.optimization,
        });
        root_module.addImport("architecture_coverage_runtime", coverage_runtime);
        kernel.sanitize_coverage_trace_pc_guard = true;
    }
    kernel.setLinkerScript(build.path(linkerScript(
        build_configuration,
        options.instrumentation,
    )));
    return kernel;
}

pub fn linkerScript(
    build_configuration: configuration.BuildConfig,
    instrumentation: Instrumentation,
) []const u8 {
    if (instrumentation == .sanitizer_guards) return switch (build_configuration.architecture) {
        .x86_32 => "tests/architecture/linker/x86_32_coverage.ld",
        .x86_64 => "tests/architecture/linker/x86_64_coverage.ld",
    };
    return switch (build_configuration.architecture) {
        .x86_32 => "src/architecture/x86/32/linker_multiboot.ld",
        .x86_64 => build_configuration.kernel_linker_script,
    };
}
