// Modified from OS Dev: https://wiki.osdev.org/Zig_Bare_Bones
const std = @import("std");

const artifacts = @import("build/artifacts.zig");
const configuration = @import("build/configuration.zig");
const documentation = @import("build/documentation.zig");
const run = @import("build/run.zig");
const unit_tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const architecture = b.option(
        configuration.Architecture,
        "arch",
        "Target architecture",
    ) orelse .x86_64;
    const bootloader = b.option(
        configuration.Bootloader,
        "bootloader",
        "Bootloader path for x86_32; x86_64 uses Limine",
    ) orelse .limine;

    const config = configuration.resolve(b, architecture, bootloader);
    const root_task = configuration.resolveRootTaskArtifact(b, config);
    const kernel_artifacts = artifacts.addKernelAndRootTask(b, config, optimize, root_task);

    unit_tests.addStep(b, optimize);
    unit_tests.addCoverageStep(b);
    documentation.addSteps(b, optimize);
    run.addStep(b, config, kernel_artifacts.kernel, kernel_artifacts.root_task);
}
