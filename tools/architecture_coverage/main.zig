const std = @import("std");
const coverage_points_file = @import("coverage_points_file");
const coverage_report = @import("coverage_report");

const architecture_source_prefix = "src/architecture/";

const CommandArguments = struct {
    points_file_path: []const u8,
    repository_root: []const u8,
    architecture_name: []const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try parseCommandArguments();
    const parsed_points = try coverage_points_file.read(
        allocator,
        arguments.points_file_path,
        arguments.architecture_name,
    );
    defer parsed_points.deinit(allocator);

    const coverage_scopes = try createCoverageScopes(allocator, arguments);
    defer freeCoverageScopes(allocator, &coverage_scopes);
    var summary = try coverage_report.summarizeScopes(
        allocator,
        &coverage_scopes,
        parsed_points.source_points,
    );
    defer summary.deinit(allocator);
    try writeReport(arguments.architecture_name, summary);
}

fn parseCommandArguments() !CommandArguments {
    var process_arguments = std.process.args();
    _ = process_arguments.next();
    const arguments: CommandArguments = .{
        .points_file_path = process_arguments.next() orelse
            return error.MissingPointsPath,
        .repository_root = process_arguments.next() orelse
            return error.MissingRepositoryRoot,
        .architecture_name = process_arguments.next() orelse
            return error.MissingArchitecture,
    };
    if (process_arguments.next() != null) return error.UnexpectedArgument;
    return arguments;
}

fn createCoverageScopes(
    allocator: std.mem.Allocator,
    arguments: CommandArguments,
) ![4]coverage_report.Scope {
    const architecture_directory = try architectureSourceDirectory(
        arguments.architecture_name,
    );
    return .{
        try createScope(
            allocator,
            arguments.repository_root,
            "src/architecture/architecture.zig",
            .file,
        ),
        try createScope(
            allocator,
            arguments.repository_root,
            "src/architecture/early_allocator.zig",
            .file,
        ),
        try createScope(
            allocator,
            arguments.repository_root,
            "src/architecture/x86/common",
            .directory,
        ),
        try createScope(
            allocator,
            arguments.repository_root,
            architecture_directory,
            .directory,
        ),
    };
}

fn architectureSourceDirectory(architecture_name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, architecture_name, "x86_32")) {
        return "src/architecture/x86/32";
    }
    if (std.mem.eql(u8, architecture_name, "x86_64")) {
        return "src/architecture/x86/64";
    }
    return error.InvalidArchitecture;
}

fn createScope(
    allocator: std.mem.Allocator,
    repository_root: []const u8,
    repository_path: []const u8,
    kind: coverage_report.Scope.Kind,
) !coverage_report.Scope {
    if (!std.mem.startsWith(u8, repository_path, architecture_source_prefix)) {
        return error.InvalidArchitectureSourcePath;
    }
    return .{
        .absolute_path = try std.fs.path.join(
            allocator,
            &.{ repository_root, repository_path },
        ),
        .display_path = repository_path[architecture_source_prefix.len..],
        .kind = kind,
    };
}

fn freeCoverageScopes(
    allocator: std.mem.Allocator,
    coverage_scopes: []const coverage_report.Scope,
) void {
    for (coverage_scopes) |scope| allocator.free(scope.absolute_path);
}

fn writeReport(
    architecture_name: []const u8,
    summary: coverage_report.Summary,
) !void {
    var output_buffer: [4096]u8 = undefined;
    var output = std.fs.File.stdout().writer(&output_buffer);
    try output.interface.print(
        "Architecture coverage: {s}\n\n",
        .{architecture_name},
    );
    try coverage_report.writeTable(&output.interface, summary);
    try output.interface.flush();
}
