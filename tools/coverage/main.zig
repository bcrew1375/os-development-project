const builtin = @import("builtin");
const std = @import("std");
const report = @import("coverage_report");

pub const std_options: std.Options = .{
    .logFn = log,
};

var logged_errors: usize = 0;

const max_coverage_points = 100_000;

extern var coverage_program_counters: [max_coverage_points]usize;
extern var coverage_values: [max_coverage_points]u8;
extern var coverage_point_count: usize;

const Counters = struct {
    values: []u8,
    program_counters: []const usize,
};

pub fn main(init: std.process.Init) void {
    @disableInstrumentation();
    run(init) catch |err| {
        std.debug.print("coverage failed: {s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    @disableInstrumentation();
    var args = init.minimal.args.iterate();
    _ = args.next();
    const common_root_argument = args.next() orelse return error.MissingCommonRoot;
    if (args.next() != null) return error.UnexpectedArgument;

    const allocator = std.heap.page_allocator;
    const canonical_common_root = try std.Io.Dir.cwd().realPathFileAlloc(
        init.io,
        common_root_argument,
        allocator,
    );
    defer allocator.free(canonical_common_root);
    const common_root = try allocator.dupe(u8, canonical_common_root);
    defer allocator.free(common_root);

    const counters = try coverageCounters();
    if (counters.values.len == 0 or counters.program_counters.len == 0) {
        return error.MissingCoverageInstrumentation;
    }
    if (counters.values.len != counters.program_counters.len) {
        return error.InvalidInstrumentationTables;
    }

    const seen = try allocator.alloc(bool, counters.values.len);
    defer allocator.free(seen);
    @memset(seen, false);
    @memset(counters.values, 0);

    const test_result = runTests(counters.values, seen);

    const points = try resolveSourcePoints(init.io, allocator, counters.program_counters, seen);
    defer {
        for (points) |point| allocator.free(point.path);
        allocator.free(points);
    }

    var summary = try report.summarize(init.io, allocator, common_root, points);
    defer summary.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try report.write(&stdout_writer.interface, summary);
    try stdout_writer.interface.print("\n{d} passed; {d} skipped; {d} failed.\n", .{
        test_result.passed,
        test_result.skipped,
        test_result.failed,
    });
    if (test_result.leaks != 0) {
        try stdout_writer.interface.print("{d} tests leaked memory.\n", .{test_result.leaks});
    }
    if (logged_errors != 0) {
        try stdout_writer.interface.print("{d} errors were logged.\n", .{logged_errors});
    }
    try stdout_writer.interface.flush();

    if (test_result.failed != 0 or test_result.leaks != 0 or logged_errors != 0) {
        std.process.exit(1);
    }
}

const TestResult = struct {
    passed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    leaks: usize = 0,
};

fn runTests(counters: []const u8, seen: []bool) TestResult {
    @disableInstrumentation();
    var result: TestResult = .{};
    for (builtin.test_functions, 0..) |test_function, index| {
        std.testing.allocator_instance = .{};
        std.testing.log_level = .warn;
        std.debug.print("{d}/{d} {s}...", .{
            index + 1,
            builtin.test_functions.len,
            test_function.name,
        });

        if (test_function.func()) |_| {
            result.passed += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                result.skipped += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                result.failed += 1;
                std.debug.print("FAIL ({s})\n", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }

        if (std.testing.allocator_instance.deinit() == .leak) result.leaks += 1;

        for (counters, seen) |counter, *was_seen| {
            was_seen.* = was_seen.* or counter != 0;
        }
        @memset(@constCast(counters), 0);
    }
    return result;
}

fn resolveSourcePoints(
    io: std.Io,
    allocator: std.mem.Allocator,
    program_counters: []const usize,
    seen: []const bool,
) ![]report.SourcePoint {
    @disableInstrumentation();
    const debug_info = try std.debug.getSelfDebugInfo();

    var points: std.ArrayListUnmanaged(report.SourcePoint) = .empty;
    errdefer {
        for (points.items) |point| allocator.free(point.path);
        points.deinit(allocator);
    }

    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    defer symbols.deinit(allocator);

    for (program_counters, seen) |address, covered| {
        if (address == 0) continue;
        symbols.clearRetainingCapacity();
        debug_info.getSymbols(io, allocator, allocator, address, false, &symbols) catch continue;
        if (symbols.items.len == 0) continue;
        const location = symbols.items[0].source_location orelse continue;
        const line = std.math.cast(u32, location.line) orelse {
            allocator.free(location.file_name);
            continue;
        };
        points.append(allocator, .{
            .path = location.file_name,
            .line = line,
            .covered = covered,
            .coverable = true,
        }) catch |err| {
            allocator.free(location.file_name);
            return err;
        };
    }
    return points.toOwnedSlice(allocator);
}

fn coverageCounters() !Counters {
    @disableInstrumentation();
    if (coverage_point_count > max_coverage_points) return error.InvalidInstrumentationTables;
    return .{
        .values = coverage_values[0..coverage_point_count],
        .program_counters = coverage_program_counters[0..coverage_point_count],
    };
}

fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    arguments: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err)) logged_errors +|= 1;
    if (@intFromEnum(level) <= @intFromEnum(std.testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", arguments);
    }
}
