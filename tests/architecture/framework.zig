pub const TestFunction = *const fn () anyerror!void;

pub const manifest = @import("manifest.zig");
pub const ExecutionMode = manifest.ExecutionMode;
pub const TestId = manifest.TestId;

pub const TestCase = struct {
    id: TestId,
    name: []const u8,
    mode: ExecutionMode,
    function: TestFunction,
};

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
};

pub const TestError = error{
    ExpectationFailed,
    ValuesNotEqual,
};

pub fn expect(condition: bool) TestError!void {
    if (!condition) return TestError.ExpectationFailed;
}

pub fn expectEqual(expected: anytype, actual: @TypeOf(expected)) TestError!void {
    if (expected != actual) return TestError.ValuesNotEqual;
}

pub fn runAll(
    writer: anytype,
    architecture_name: []const u8,
    execution_mode: ExecutionMode,
    test_cases: []const TestCase,
) Summary {
    writer.print("QEMU-TEST protocol=2 arch={s} mode={s} tests={d}\n", .{
        architecture_name,
        @tagName(execution_mode),
        test_cases.len,
    }) catch {};

    var summary: Summary = .{};
    for (test_cases) |test_case| {
        writer.print("QEMU-TEST RUN id={s} name=\"{s}\"\n", .{
            @tagName(test_case.id),
            test_case.name,
        }) catch {};
        test_case.function() catch |err| {
            summary.failed += 1;
            writer.print("QEMU-TEST FAIL id={s} error={s}\n", .{
                @tagName(test_case.id),
                @errorName(err),
            }) catch {};
            continue;
        };

        summary.passed += 1;
        writer.print("QEMU-TEST PASS id={s}\n", .{@tagName(test_case.id)}) catch {};
    }

    writer.print("QEMU-TEST SUMMARY passed={d} failed={d}\n", .{
        summary.passed,
        summary.failed,
    }) catch {};
    return summary;
}
