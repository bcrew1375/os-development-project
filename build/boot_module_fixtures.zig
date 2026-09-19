const std = @import("std");

const fixture = @import("../tests/architecture/boot_module_fixture.zig");

pub const Fixtures = struct {
    paths: []const std.Build.LazyPath,
    names: []const []const u8,
};

pub fn create(build: *std.Build) Fixtures {
    const generated_files = build.addWriteFiles();
    const paths = build.allocator.alloc(
        std.Build.LazyPath,
        fixture.supplied_module_count,
    ) catch @panic("OOM");
    const names = build.allocator.alloc(
        []const u8,
        fixture.supplied_module_count,
    ) catch @panic("OOM");

    for (paths, names, 0..) |*path, *name, index| {
        const payload = build.allocator.alloc(u8, fixture.payloadSize(index)) catch @panic("OOM");
        @memset(payload, fixture.payloadByte(index));

        var name_buffer: [32]u8 = undefined;
        name.* = build.dupe(fixture.fileName(&name_buffer, index));
        path.* = generated_files.add(name.*, payload);
    }

    return .{
        .paths = paths,
        .names = names,
    };
}

pub fn createLimineConfig(build: *std.Build, fixtures: Fixtures) std.Build.LazyPath {
    var config: std.ArrayList(u8) = .empty;
    const writer = config.writer(build.allocator);
    writer.writeAll(
        \\graphics: no
        \\timeout: 0
        \\verbose: yes
        \\
        \\/Architecture boot-module tests x86_64
        \\    protocol: limine
        \\    kernel_path: boot():/boot/kernel.elf
        \\
    ) catch @panic("OOM");
    for (fixtures.names) |name| {
        writer.print("    module_path: boot():/boot/{s}\n", .{name}) catch @panic("OOM");
    }

    const generated_files = build.addWriteFiles();
    return generated_files.add("x86_64-boot-modules.conf", config.items);
}
