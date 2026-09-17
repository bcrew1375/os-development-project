pub const TestFunction = *const fn () anyerror!void;

pub const TestCase = struct {
    name: []const u8,
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
    test_cases: []const TestCase,
) Summary {
    writer.print("QEMU-TEST protocol=1 arch={s} tests={d}\n", .{
        architecture_name,
        test_cases.len,
    }) catch {};

    var summary: Summary = .{};
    for (test_cases) |test_case| {
        writer.print("QEMU-TEST RUN name=\"{s}\"\n", .{test_case.name}) catch {};
        test_case.function() catch |err| {
            summary.failed += 1;
            writer.print("QEMU-TEST FAIL name=\"{s}\" error={s}\n", .{
                test_case.name,
                @errorName(err),
            }) catch {};
            continue;
        };

        summary.passed += 1;
        writer.print("QEMU-TEST PASS name=\"{s}\"\n", .{test_case.name}) catch {};
    }

    writer.print("QEMU-TEST SUMMARY passed={d} failed={d}\n", .{
        summary.passed,
        summary.failed,
    }) catch {};
    return summary;
}
