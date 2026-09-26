const std = @import("std");

const configuration = @import("configuration.zig");
const limine = @import("limine.zig");
const production_boot_modules = @import("production_boot_modules.zig");

pub fn addStep(
    build: *std.Build,
    build_configuration: configuration.BuildConfig,
    kernel: *std.Build.Step.Compile,
    root_task: configuration.RootTaskArtifact,
) void {
    const timeout_seconds = resolveTimeoutSeconds(build);
    const system_smoke = build.step(
        "system-smoke",
        "Boot the production kernel and root task under QEMU",
    );
    const child_module = production_boot_modules.createChildModule(
        build,
        build_configuration.architecture,
    );
    const command = build.addSystemCommand(&.{"python3"});
    command.addFileArg(build.path("tools/system_smoke_runner.py"));
    command.addArgs(&.{
        "--architecture",
        @tagName(build_configuration.architecture),
        "--image-kind",
    });

    switch (build_configuration.bootloader) {
        .multiboot => {
            command.addArg("kernel");
            command.addArg("--image");
            command.addFileArg(kernel.getEmittedBin());
            command.addArg("--boot-module");
            command.addFileArg(root_task.path);
            command.addArg("--boot-module");
            command.addFileArg(child_module);
        },
        .limine => {
            const iso = limine.createIso(
                build,
                kernel.getEmittedBin(),
                build.path(configuration.limineConfigPath(build_configuration.architecture)),
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
                build.fmt(
                    "system-smoke-{s}.iso",
                    .{@tagName(build_configuration.architecture)},
                ),
            );
            command.addArg("cdrom");
            command.addArg("--image");
            command.addFileArg(iso);
        },
    }

    command.addArgs(&.{
        "--timeout-seconds",
        build.fmt("{d}", .{timeout_seconds}),
        "--transcript-output",
    });
    _ = command.addOutputFileArg(build.fmt(
        "system-smoke-{s}.log",
        .{@tagName(build_configuration.architecture)},
    ));
    command.has_side_effects = true;
    system_smoke.dependOn(&command.step);
}

fn resolveTimeoutSeconds(build: *std.Build) u32 {
    const timeout_seconds = build.option(
        u32,
        "system-smoke-timeout",
        "Maximum production system-smoke runtime in seconds",
    ) orelse 60;
    if (timeout_seconds == 0) {
        std.debug.panic("-Dsystem-smoke-timeout must be greater than zero", .{});
    }
    return timeout_seconds;
}
