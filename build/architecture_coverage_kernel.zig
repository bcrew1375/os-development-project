const std = @import("std");

const architecture_test_kernel = @import("architecture_test_kernel.zig");
const configuration = @import("configuration.zig");

const coverage_optimization: std.builtin.OptimizeMode = .ReleaseFast;

pub const Artifacts = struct {
    original_llvm_ir: std.Build.LazyPath,
    instrumented_kernel_elf: std.Build.LazyPath,
};

pub fn add(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
) Artifacts {
    const compiler_output = architecture_test_kernel.addKernel(build, build_configuration, .{
        .executable_name = "architecture-coverage-source.elf",
        .entry_point_source = "tests/architecture/coverage_main.zig",
        .optimization = coverage_optimization,
        .instrumentation = .sanitizer_guards,
    });
    const original_llvm_ir = compiler_output.getEmittedLlvmIr();
    return .{
        .original_llvm_ir = original_llvm_ir,
        .instrumented_kernel_elf = relinkCompatibleLlvmIr(
            build,
            build_configuration,
            original_llvm_ir,
        ),
    };
}

pub fn install(
    build: *std.Build,
    install_step: *std.Build.Step,
    artifacts: Artifacts,
) void {
    const install_kernel = build.addInstallFileWithDir(
        artifacts.instrumented_kernel_elf,
        .{ .custom = "architecture-coverage" },
        "architecture-coverage.elf",
    );
    const install_llvm_ir = build.addInstallFileWithDir(
        artifacts.original_llvm_ir,
        .{ .custom = "architecture-coverage" },
        "architecture-coverage.ll",
    );
    install_step.dependOn(&install_kernel.step);
    install_step.dependOn(&install_llvm_ir.step);
}

fn relinkCompatibleLlvmIr(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    original_llvm_ir: std.Build.LazyPath,
) std.Build.LazyPath {
    const compatible_llvm_ir = rewriteLlvmIr(
        build,
        build_configuration.architecture,
        original_llvm_ir,
    );
    const link_kernel = createLinkCommand(build, build_configuration);
    const instrumented_kernel_elf = link_kernel.addPrefixedOutputFileArg(
        "-femit-bin=",
        "architecture-coverage.elf",
    );
    link_kernel.addFileArg(compatible_llvm_ir);
    return instrumented_kernel_elf;
}

fn rewriteLlvmIr(
    build: *std.Build,
    architecture: configuration.Architecture,
    original_llvm_ir: std.Build.LazyPath,
) std.Build.LazyPath {
    const rewrite_llvm_ir = build.addSystemCommand(&.{"python3"});
    rewrite_llvm_ir.addFileArg(build.path("tools/architecture_coverage/rewrite_ir.py"));
    rewrite_llvm_ir.addFileArg(original_llvm_ir);
    rewrite_llvm_ir.addArg(@tagName(architecture));
    return rewrite_llvm_ir.addOutputFileArg("architecture-coverage-compatible.ll");
}

fn createLinkCommand(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
) *std.Build.Step.Run {
    const link_kernel = build.addSystemCommand(&.{
        build.graph.zig_exe,
        "build-exe",
        "-fllvm",
        "-flld",
    });
    link_kernel.addArg(optimizationArgument(coverage_optimization));
    if (configuration.codeModelArgument(build_configuration.kernel_code_model)) |argument| {
        link_kernel.addArg(argument);
    }
    link_kernel.addArgs(&.{
        "-target",
        configuration.targetTriple(build_configuration.architecture),
        "-mcpu",
        configuration.cpuFeatures(build_configuration.architecture),
        "--script",
        build.pathFromRoot(architecture_test_kernel.linkerScript(
            build_configuration,
            .sanitizer_guards,
        )),
    });
    return link_kernel;
}

fn optimizationArgument(optimization: std.builtin.OptimizeMode) []const u8 {
    return switch (optimization) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        .ReleaseFast => "-OReleaseFast",
        .ReleaseSmall => "-OReleaseSmall",
    };
}
