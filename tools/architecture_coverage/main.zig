const std = @import("std");
const coverage_points_file = @import("coverage_points_file");
const coverage_report = @import("coverage_report");
const source_manifest = @import("source_manifest");

const architecture_source_prefix = "src/architecture/";

const CommandArguments = struct {
    points_file_path: []const u8,
    repository_root: []const u8,
    architecture_name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const arguments = try parseCommandArguments(&init.minimal.args);
    const parsed_points = try coverage_points_file.read(
        init.io,
        allocator,
        arguments.points_file_path,
        arguments.architecture_name,
    );
    defer parsed_points.deinit(allocator);

    const coverage_scopes = try createCoverageScopes(allocator, arguments);
    defer freeCoverageScopes(allocator, coverage_scopes);
    var summary = try coverage_report.summarizeScopes(
        init.io,
        allocator,
        coverage_scopes,
        parsed_points.source_points,
    );
    defer summary.deinit(allocator);
    try writeReport(init.io, arguments.architecture_name, summary);
}

fn parseCommandArguments(args: *const std.process.Args) !CommandArguments {
    var process_arguments = args.iterate();
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
) ![]coverage_report.Scope {
    const manifest_scopes = try source_manifest.scopesForArchitecture(
        arguments.architecture_name,
    );
    const coverage_scopes = try allocator.alloc(
        coverage_report.Scope,
        manifest_scopes.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (coverage_scopes[0..initialized]) |scope| allocator.free(scope.absolute_path);
        allocator.free(coverage_scopes);
    }

    for (manifest_scopes, coverage_scopes) |manifest_scope, *coverage_scope| {
        coverage_scope.* = try createScope(
            allocator,
            arguments.repository_root,
            manifest_scope.repository_path,
            switch (manifest_scope.kind) {
                .file => .file,
                .directory => .directory,
            },
        );
        initialized += 1;
    }
    return coverage_scopes;
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
    allocator.free(coverage_scopes);
}

fn writeReport(
    io: std.Io,
    architecture_name: []const u8,
    summary: coverage_report.Summary,
) !void {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.print(
        "Architecture coverage: {s}\n\n",
        .{architecture_name},
    );
    try coverage_report.writeTable(&output.interface, summary);
    try output.interface.flush();
}
