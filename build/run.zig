const std = @import("std");

const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const production_boot_modules = @import("production_boot_modules.zig");

pub fn addStep(
    b: *std.Build,
    config: configuration.BuildConfig,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
) void {
    const child_module = production_boot_modules.createChildModule(b, config.architecture);
    const run_step = b.step("run", "Run kernel with qemu");
    const run_command = switch (config.bootloader) {
        .multiboot => createDirectKernelRunStep(b, kernel, root_task, child_module),
        .limine => createLimineRunStep(b, config, kernel, root_task, child_module),
    };

    run_command.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_command.step);
}

fn createDirectKernelRunStep(
    b: *std.Build,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
    child_module: std.Build.LazyPath,
) *std.Build.Step.Run {
    const script =
        \\set -eu
        \\kernel="$1"
        \\root_task="$2"
        \\child_module="$3"
        \\shift 3
        \\exec qemu-system-i386 "$@" -kernel "$kernel" -initrd "$root_task,$child_module"
    ;
    const qemu_cmd = b.addSystemCommand(&.{ "bash", "-c", script, "run-multiboot" });

    qemu_cmd.addFileArg(kernel.getEmittedBin());
    qemu_cmd.addFileArg(root_task.path);
    qemu_cmd.addFileArg(child_module);
    qemu_cmd.addArgs(direct_qemu_args[1..]);

    return qemu_cmd;
}

fn createLimineRunStep(
    b: *std.Build,
    config: configuration.BuildConfig,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
    child_module: std.Build.LazyPath,
) *std.Build.Step.Run {
    const iso = limine.createIso(
        b,
        kernel.getEmittedBin(),
        b.path(configuration.limineConfigPath(config.architecture)),
        &.{
            .{
                .source = root_task.path,
                .iso_name = "root_process.elf",
            },
            .{
                .source = child_module,
                .iso_name = production_boot_modules.child_module_name,
            },
        },
        b.fmt("kernel-{s}.iso", .{@tagName(config.architecture)}),
    );

    const qemu_cmd = b.addSystemCommand(limineQemuArgs(config.architecture));
    qemu_cmd.addArg("-cdrom");
    qemu_cmd.addFileArg(iso);

    return qemu_cmd;
}

const direct_qemu_args = [_][]const u8{
    // zig fmt: off
    "qemu-system-i386",
    "-vnc", "127.0.0.1:0",
    "-chardev", "file,id=serial0,path=serial.log",
    "-serial", "chardev:serial0",
    "-s",
    "-m", "128M",
    "-daemonize",
    "-pidfile", ".qemu.pid",
    "-M", "pc,accel=tcg,smm=off",
    "-D", "qemu.log",
    "-d", "int,cpu_reset,guest_errors",
    "-no-reboot",
    "-no-shutdown",
    // zig fmt: on
};

fn limineQemuArgs(architecture: configuration.Architecture) []const []const u8 {
    return switch (architecture) {
        .x86_32 => &limine_qemu_i386_args,
        .x86_64 => &limine_qemu_x86_64_args,
    };
}

const limine_qemu_i386_args = [_][]const u8{
    // zig fmt: off
    "qemu-system-i386",
    "-vga", "std",
    "-boot", "d",
    "-vnc", "127.0.0.1:0",
    "-chardev", "file,id=serial0,path=serial.log",
    "-serial", "chardev:serial0",
    "-s",
    "-m", "128M",
    "-daemonize",
    "-pidfile", ".qemu.pid",
    "-M", "pc,accel=tcg,smm=off",
    "-D", "qemu.log",
    "-d", "int,cpu_reset,guest_errors",
    "-no-reboot",
    "-no-shutdown",
    // zig fmt: on
};

const limine_qemu_x86_64_args = [_][]const u8{
    // zig fmt: off
    "qemu-system-x86_64",
    "-vga", "std",
    "-boot", "d",
    "-vnc", "127.0.0.1:0",
    "-chardev", "file,id=serial0,path=serial.log",
    "-serial", "chardev:serial0",
    "-s",
    "-m", "128M",
    "-daemonize",
    "-pidfile", ".qemu.pid",
    "-M", "pc,accel=tcg,smm=off",
    "-D", "qemu.log",
    "-d", "int,cpu_reset,guest_errors",
    "-no-reboot",
    "-no-shutdown",
    // zig fmt: on
};
