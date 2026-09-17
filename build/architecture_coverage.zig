const std = @import("std");

const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const modules = @import("modules.zig");

pub fn addSteps(
    b: *std.Build,
    config: configuration.BuildConfig,
) void {
    const step = b.step(
        "architecture-coverage-kernel",
        "Build an instrumented architecture test kernel",
    );
    const coverage_step = b.step(
        "architecture-coverage",
        "Measure physical architecture coverage under QEMU",
    );
    if (config.architecture == .x86_32) {
        const unsupported = b.addSystemCommand(&.{
            "bash",
            "-c",
            "echo 'architecture coverage is not supported for x86_32: Zig 0.15.2 sanitizer instrumentation is incompatible with the pre-paging bootstrap' >&2; exit 1",
        });
        const unsupported_kernel = b.addSystemCommand(&.{
            "bash",
            "-c",
            "echo 'instrumented architecture coverage kernels are not supported for x86_32 with Zig 0.15.2' >&2; exit 1",
        });
        coverage_step.dependOn(&unsupported.step);
        step.dependOn(&unsupported_kernel.step);
        return;
    }
    const common_modules = modules.createCommonModules(
        b,
        config.kernel_target,
        .ReleaseFast,
        config.architecture == .x86_32,
    );
    const root_module = b.createModule(.{
        .root_source_file = b.path("tests/architecture/coverage_main.zig"),
        .target = config.kernel_target,
        .optimize = .ReleaseFast,
        .code_model = config.kernel_code_model,
    });
    const coverage_runtime = b.createModule(.{
        .root_source_file = b.path("tests/architecture/coverage/runtime.zig"),
        .target = config.kernel_target,
        .optimize = .ReleaseFast,
    });
    root_module.addImport("architecture_coverage_runtime", coverage_runtime);

    const test_kernel = b.addExecutable(.{
        .name = "architecture-coverage.elf",
        .root_module = root_module,
        .use_llvm = true,
        .use_lld = true,
    });
    modules.addCommonImports(root_module, common_modules);
    test_kernel.sanitize_coverage_trace_pc_guard = true;
    test_kernel.setLinkerScript(b.path(switch (config.architecture) {
        .x86_32 => "src/architecture/x86/32/linker_multiboot.ld",
        .x86_64 => config.kernel_linker_script,
    }));

    const rewrite_ir = b.addSystemCommand(&.{"python3"});
    rewrite_ir.addFileArg(b.path("tools/architecture_coverage/rewrite_ir.py"));
    rewrite_ir.addFileArg(test_kernel.getEmittedLlvmIr());
    const rewritten_ir = rewrite_ir.addOutputFileArg("architecture-coverage-rewritten.ll");

    const link_kernel = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-exe",
        "-fllvm",
        "-flld",
        "-OReleaseFast",
        "-mcmodel=kernel",
        "-target",
        "x86_64-freestanding-none",
        "-mcpu",
        "baseline-avx-avx2-mmx+soft_float-sse-sse2",
        "--script",
        b.pathFromRoot("src/architecture/x86/64/linker.ld"),
    });
    const final_elf = link_kernel.addPrefixedOutputFileArg(
        "-femit-bin=",
        "architecture-coverage.elf",
    );
    link_kernel.addFileArg(rewritten_ir);

    const install_kernel = b.addInstallFileWithDir(
        final_elf,
        .{ .custom = "architecture-coverage" },
        "architecture-coverage.elf",
    );
    step.dependOn(&install_kernel.step);
    const install_ir = b.addInstallFileWithDir(
        test_kernel.getEmittedLlvmIr(),
        .{ .custom = "architecture-coverage" },
        "architecture-coverage.ll",
    );
    step.dependOn(&install_ir.step);

    const iso = limine.createIso(
        b,
        final_elf,
        b.path("tests/architecture/limine/x86_64.conf"),
        null,
        "architecture-coverage-x86_64.iso",
    );
    const run_coverage = createCoverageRunStep(b, iso);
    const frame = run_coverage.addOutputFileArg("architecture-coverage.bin");

    const collect = b.addSystemCommand(&.{"python3"});
    collect.addFileArg(b.path("tools/architecture_coverage/collect.py"));
    collect.addFileArg(test_kernel.getEmittedLlvmIr());
    collect.addFileArg(final_elf);
    collect.addFileArg(frame);
    const points = collect.addOutputFileArg("architecture-coverage.tsv");

    const report_module = b.createModule(.{
        .root_source_file = b.path("tools/coverage/report.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const reporter = b.addExecutable(.{
        .name = "architecture-coverage-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/architecture_coverage/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    reporter.root_module.addImport("coverage_report", report_module);
    const run_reporter = b.addRunArtifact(reporter);
    run_reporter.addFileArg(points);
    run_reporter.addArg(b.pathFromRoot("."));
    run_reporter.has_side_effects = true;
    coverage_step.dependOn(&run_reporter.step);
}

fn createCoverageRunStep(b: *std.Build, iso: std.Build.LazyPath) *std.Build.Step.Run {
    const script =
        \\set +e
        \\iso="$1"
        \\coverage="$2"
        \\serial_log="$(mktemp)"
        \\cleanup() { rm -f "$serial_log"; }
        \\trap cleanup EXIT
        \\timeout --foreground --signal=TERM --kill-after=2s 60s qemu-system-x86_64 \
        \\    -display none -monitor none \
        \\    -chardev "file,id=serial0,path=$serial_log" -serial chardev:serial0 \
        \\    -chardev "file,id=coverage0,path=$coverage" \
        \\    -device isa-debugcon,iobase=0xe9,chardev=coverage0 \
        \\    -m 128M -M pc,accel=tcg,smm=off \
        \\    -no-reboot -no-shutdown \
        \\    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        \\    -cdrom "$iso"
        \\status=$?
        \\cat "$serial_log"
        \\case "$status" in
        \\    1) exit 0 ;;
        \\    3) echo "architecture coverage tests reported failure" >&2; exit 1 ;;
        \\    124|137) echo "architecture coverage timed out" >&2; exit 1 ;;
        \\    *) echo "QEMU terminated without a valid coverage result (status $status)" >&2; exit 1 ;;
        \\esac
    ;
    const command = b.addSystemCommand(&.{ "bash", "-c", script, "run-architecture-coverage" });
    command.addFileArg(iso);
    command.has_side_effects = true;
    return command;
}
