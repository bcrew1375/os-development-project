const std = @import("std");

pub fn expectDiagnostic(
    diagnostics: []const []const u8,
    index: usize,
    expected: []const u8,
) !void {
    try std.testing.expect(index < diagnostics.len);
    try std.testing.expectEqualStrings(expected, diagnostics[index]);
}
