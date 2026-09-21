const std = @import("std");

const configuration = @import("configuration.zig");
const limine = @import("limine.zig");

pub fn addStep(
    b: *std.Build,
    config: configuration.BuildConfig,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
) void {
    const run_step = b.step("run", "Run kernel with qemu");
    const run_command = switch (config.bootloader) {
        .multiboot => createDirectKernelRunStep(b, kernel, root_task),
        .limine => createLimineRunStep(b, config, kernel, root_task),
    };

    run_command.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_command.step);
}

fn createDirectKernelRunStep(
    b: *std.Build,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
) *std.Build.Step.Run {
    const qemu_cmd = b.addSystemCommand(&direct_qemu_args);

    qemu_cmd.addArg("-kernel");
    qemu_cmd.addFileArg(kernel.getEmittedBin());

    qemu_cmd.addArg("-initrd");
    qemu_cmd.addFileArg(root_task.path);

    return qemu_cmd;
}

fn createLimineRunStep(
    b: *std.Build,
    config: configuration.BuildConfig,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
) *std.Build.Step.Run {
    const iso = limine.createIso(
        b,
        kernel.getEmittedBin(),
        b.path(configuration.limineConfigPath(config.architecture)),
        &.{.{
            .source = root_task.path,
            .iso_name = "root_process.elf",
        }},
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