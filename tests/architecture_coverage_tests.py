#!/usr/bin/env python3

import importlib.util
import pathlib
import struct
import sys
import unittest

sys.dont_write_bytecode = True


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "architecture_coverage_collect",
    ROOT / "tools/architecture_coverage/collect.py",
)
assert SPEC and SPEC.loader
COLLECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COLLECT)


class ArchitectureCoverageTests(unittest.TestCase):
    def test_frame_parser_accepts_valid_x86_64_frame(self) -> None:
        bitmap = bytes([0b0100_0001])
        frame = COLLECT.HEADER.pack(COLLECT.MAGIC, 1, 2, 8, 7, len(bitmap))
        frame += bitmap
        point_count, parsed_bitmap = COLLECT.parse_frame(frame)
        self.assertEqual(7, point_count)
        self.assertEqual(bitmap, parsed_bitmap)

    def test_frame_parser_rejects_truncated_payload(self) -> None:
        frame = COLLECT.HEADER.pack(COLLECT.MAGIC, 1, 2, 8, 9, 2)
        with self.assertRaisesRegex(ValueError, "size"):
            COLLECT.parse_frame(frame)

    def test_ir_parser_expands_covered_block_source_lines(self) -> None:
        ir = """
@__sancov_gen_ = private global [1 x i32] zeroinitializer, section "__sancov_guards"
define void @example() {
Entry:
  call void @__sanitizer_cov_trace_pc_guard(ptr @__sancov_gen_), !dbg !4
  br label %sanitizer_merge, !dbg !4
sanitizer_merge:
  call void asm sideeffect "one", ""(), !dbg !7
  call void asm sideeffect "two", ""(), !dbg !8
  ret void
}
!1 = !DIFile(filename: "inner.zig", directory: "/workspace/src/architecture")
!2 = !DIFile(filename: "outer.zig", directory: "/workspace/src/architecture")
!3 = distinct !DISubprogram(name: "inner", file: !1, scope: !1)
!4 = !DILocation(line: 11, scope: !3, inlinedAt: !6)
!5 = distinct !DISubprogram(name: "outer", file: !2, scope: !2)
!6 = !DILocation(line: 22, scope: !5)
!7 = !DILocation(line: 12, scope: !3, inlinedAt: !6)
!8 = !DILocation(line: 14, scope: !3, inlinedAt: !6)
"""
        points, point_count = COLLECT.coverage_points(ir, bytes([1]))
        self.assertEqual(1, point_count)
        self.assertIn(("/workspace/src/architecture/inner.zig", 11, True), points)
        self.assertIn(("/workspace/src/architecture/inner.zig", 12, True), points)
        self.assertIn(("/workspace/src/architecture/inner.zig", 14, True), points)
        self.assertIn(("/workspace/src/architecture/outer.zig", 22, True), points)

    def test_ir_parser_keeps_unseen_block_lines_uncovered(self) -> None:
        ir = """
@__sancov_gen_ = private global [2 x i32] zeroinitializer, section "__sancov_guards"
define void @example() {
Entry:
  call void @__sanitizer_cov_trace_pc_guard(ptr @__sancov_gen_), !dbg !3
  call void asm sideeffect "covered", ""(), !dbg !4
Other:
  call void @__sanitizer_cov_trace_pc_guard(ptr getelementptr inbounds ([2 x i32], ptr @__sancov_gen_, i64 0, i64 1)), !dbg !5
  call void asm sideeffect "uncovered", ""(), !dbg !6
  ret void
}
!1 = !DIFile(filename: "example.zig", directory: "/workspace/src/architecture")
!2 = distinct !DISubprogram(name: "example", file: !1, scope: !1)
!3 = !DILocation(line: 10, scope: !2)
!4 = !DILocation(line: 11, scope: !2)
!5 = !DILocation(line: 20, scope: !2)
!6 = !DILocation(line: 21, scope: !2)
"""
        points, point_count = COLLECT.coverage_points(ir, bytes([0b0000_0001]))
        self.assertEqual(2, point_count)
        self.assertIn(("/workspace/src/architecture/example.zig", 11, True), points)
        self.assertIn(("/workspace/src/architecture/example.zig", 21, False), points)


if __name__ == "__main__":
    unittest.main()