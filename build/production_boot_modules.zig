const std = @import("std");
const configuration = @import("configuration.zig");

pub const child_module_name = "child_process.elf";

pub fn createChildModule(
    build: *std.Build,
    architecture: configuration.Architecture,
) std.Build.LazyPath {
    const script =
        \\set -eu
        \\architecture="$1"
        \\output="$2"
        \\zig_exe="$3"
        \\root_task_directory="$4"
        \\abi_directory="$5"
        \\cd "$root_task_directory"
        \\"$zig_exe" build -Darch="$architecture" \
        \\    -Dabi-path="$abi_directory/src/abi/main.zig" \
        \\    -Dshared-path="$abi_directory/src/main.zig"
        \\mkdir -p "$(dirname "$output")"
        \\cp "zig-out/$architecture/bin/child_process.elf" "$output"
    ;
    const command = build.addSystemCommand(&.{ "bash", "-c", script, "build-child" });
    command.has_side_effects = true;
    command.addArg(@tagName(architecture));
    const output = command.addOutputFileArg(build.fmt("child_process-{s}.elf", .{@tagName(architecture)}));
    command.addArg(build.graph.zig_exe);
    command.addDirectoryArg(build.path("components/os-root-task"));
    command.addDirectoryArg(build.path("components/os-abi-library"));
    return output;
}
