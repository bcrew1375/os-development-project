const std = @import("std");

const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const modules = @import("modules.zig");

pub fn addStep(b: *std.Build, config: configuration.BuildConfig) void {
    const step = b.step("architecture-tests", "Run physical architecture tests under QEMU");
    const timeout_seconds = b.option(
        u32,
        "architecture-test-timeout",
        "Maximum QEMU architecture-test runtime in seconds",
    ) orelse 60;
    if (timeout_seconds == 0) {
        std.debug.panic("-Darchitecture-test-timeout must be greater than zero", .{});
    }
    const common_modules = modules.createCommonModules(
        b,
        config.kernel_target,
        .Debug,
        config.architecture == .x86_32,
    );
    const test_kernel = b.addExecutable(.{
        .name = "architecture-tests.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/architecture/main.zig"),
            .target = config.kernel_target,
            .optimize = .Debug,
            .code_model = config.kernel_code_model,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    modules.addCommonImports(test_kernel.root_module, common_modules);
    const test_linker_script = switch (config.architecture) {
        .x86_32 => "src/architecture/x86/32/linker_multiboot.ld",
        .x86_64 => config.kernel_linker_script,
    };
    test_kernel.setLinkerScript(b.path(test_linker_script));

    const run_command = switch (config.architecture) {
        .x86_32 => createQemuCommand(
            b,
            config.architecture,
            "kernel",
            test_kernel.getEmittedBin(),
            timeout_seconds,
        ),
        .x86_64 => createQemuCommand(
            b,
            config.architecture,
            "cdrom",
            limine.createIso(
                b,
                test_kernel.getEmittedBin(),
                b.path(testLimineConfigPath(config.architecture)),
                null,
                b.fmt("architecture-tests-{s}.iso", .{@tagName(config.architecture)}),
            ),
            timeout_seconds,
        ),
    };
    run_command.has_side_effects = true;
    step.dependOn(&run_command.step);
}

fn createQemuCommand(
    b: *std.Build,
    architecture: configuration.Architecture,
    image_option: []const u8,
    image: std.Build.LazyPath,
    timeout_seconds: u32,
) *std.Build.Step.Run {
    const script =
        \\set +e
        \\qemu="$1"
        \\image_option="$2"
        \\image="$3"
        \\timeout_seconds="$4"
        \\serial_log="$(mktemp)"
        \\cleanup() {
        \\    rm -f "$serial_log"
        \\}
        \\trap cleanup EXIT
        \\echo "Launching architecture tests with $qemu ($image_option: $image)" >&2
        \\timeout --foreground --signal=TERM --kill-after=2s "${timeout_seconds}s" "$qemu" \
        \\    -display none \
        \\    -monitor none \
        \\    -chardev "file,id=serial0,path=$serial_log" \
        \\    -serial chardev:serial0 \
        \\    -m 128M \
        \\    -M pc,accel=tcg,smm=off \
        \\    -no-reboot \
        \\    -no-shutdown \
        \\    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        \\    "-$image_option" "$image"
        \\status=$?
        \\cat "$serial_log"
        \\case "$status" in
        \\    1) exit 0 ;;
        \\    3) echo "architecture test suite reported failure" >&2; exit 1 ;;
        \\    124|137) echo "architecture tests timed out after $timeout_seconds seconds before reporting completion" >&2; exit 1 ;;
        \\    *) echo "QEMU terminated without a valid test result (status $status)" >&2; exit 1 ;;
        \\esac
    ;
    const command = b.addSystemCommand(&.{ "bash", "-c", script, "run-architecture-tests" });
    command.addArg(switch (architecture) {
        .x86_32 => "qemu-system-i386",
        .x86_64 => "qemu-system-x86_64",
    });
    command.addArg(image_option);
    command.addFileArg(image);
    command.addArg(b.fmt("{d}", .{timeout_seconds}));
    return command;
}

fn testLimineConfigPath(architecture: configuration.Architecture) []const u8 {
    return switch (architecture) {
        .x86_32 => unreachable,
        .x86_64 => "tests/architecture/limine/x86_64.conf",
    };
}
