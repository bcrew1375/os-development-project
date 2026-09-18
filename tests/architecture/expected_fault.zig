const registry = @import("registry.zig");
const transport = @import("transport.zig");

pub fn observe(
    vector: usize,
    error_code: usize,
    instruction_pointer: usize,
    cr2: usize,
) bool {
    if (registry.execution_mode != .expected_fault) return false;

    const test_case = registry.tests[0];
    const expectation = registry.manifest.find(test_case.id).expected_fault.?;
    const error_code_matches =
        error_code & expectation.error_code_mask == expectation.error_code_value;
    const cr2_matches = expectation.cr2 == null or expectation.cr2.? == cr2;
    const matches = expectation.vector == vector and error_code_matches and cr2_matches;
    const writer = transport.writer();

    writer.print(
        "QEMU-TEST {s} id={s} vector={d} error_code=0x{x} " ++
            "instruction_pointer=0x{x} cr2=0x{x} present={d} write={d} " ++
            "user={d} reserved={d} instruction_fetch={d}\n",
        .{
            if (matches) "FAULT" else "UNEXPECTED-FAULT",
            @tagName(test_case.id),
            vector,
            error_code,
            instruction_pointer,
            cr2,
            @intFromBool((error_code & 0x01) != 0),
            @intFromBool((error_code & 0x02) != 0),
            @intFromBool((error_code & 0x04) != 0),
            @intFromBool((error_code & 0x08) != 0),
            @intFromBool((error_code & 0x10) != 0),
        },
    ) catch {};
    transport.exit(if (matches) .success else .failure);
}
