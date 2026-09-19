#!/usr/bin/env python3

import importlib.util
import pathlib
import sys
import tempfile
import types
import unittest

sys.dont_write_bytecode = True


ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL_ROOT = ROOT / "tools/architecture_coverage"
sys.path.insert(0, str(TOOL_ROOT))


def load_module(name: str, path: pathlib.Path | None = None):
    module_path = path or TOOL_ROOT / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, module_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


FRAME = load_module("frame")
LLVM_IR = load_module("llvm_ir")
COLLECT = load_module("collect")
REWRITE_IR = load_module("rewrite_ir")
ARCHITECTURE_TEST_RUNNER = load_module(
    "architecture_test_runner",
    ROOT / "tools/architecture_test_runner.py",
)


class ArchitectureCoverageTests(unittest.TestCase):
    def test_frame_parser_accepts_valid_x86_64_frame(self) -> None:
        bitmap = bytes([0b0100_0001])
        data = FRAME.HEADER.pack(FRAME.MAGIC, 1, 2, 8, 7, len(bitmap)) + bitmap
        parsed = FRAME.parse(data)
        self.assertEqual("x86_64", parsed.architecture)
        self.assertEqual(7, parsed.instrumentation_point_count)
        self.assertEqual(bitmap, parsed.covered_points_bitmap)

    def test_frame_parser_accepts_valid_x86_32_frame(self) -> None:
        bitmap = bytes([0b0000_0011])
        data = FRAME.HEADER.pack(FRAME.MAGIC, 1, 1, 4, 2, len(bitmap)) + bitmap
        parsed = FRAME.parse(data)
        self.assertEqual("x86_32", parsed.architecture)
        self.assertEqual(2, parsed.instrumentation_point_count)
        self.assertEqual(bitmap, parsed.covered_points_bitmap)

    def test_frame_parser_rejects_truncated_payload(self) -> None:
        frame = FRAME.HEADER.pack(FRAME.MAGIC, 1, 2, 8, 9, 2)
        with self.assertRaisesRegex(ValueError, "size"):
            FRAME.parse(frame)

    def test_frame_parser_rejects_pointer_width_mismatch(self) -> None:
        frame = FRAME.HEADER.pack(FRAME.MAGIC, 1, 1, 8, 0, 0)
        with self.assertRaisesRegex(ValueError, "pointer width"):
            FRAME.parse(frame)

    def test_frame_parser_rejects_unknown_version(self) -> None:
        frame = FRAME.HEADER.pack(FRAME.MAGIC, 2, 2, 8, 0, 0)
        with self.assertRaisesRegex(ValueError, "version"):
            FRAME.parse(frame)

    def test_ir_parser_expands_covered_block_source_lines(self) -> None:
        llvm_ir_text = """
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
        source_points, instrumentation_point_count = LLVM_IR.coverage_points(
            llvm_ir_text,
            bytes([1]),
        )
        self.assertEqual(1, instrumentation_point_count)
        self.assertIn(
            ("/workspace/src/architecture/inner.zig", 11, True),
            source_points,
        )
        self.assertIn(
            ("/workspace/src/architecture/inner.zig", 12, True),
            source_points,
        )
        self.assertIn(
            ("/workspace/src/architecture/inner.zig", 14, True),
            source_points,
        )
        self.assertIn(
            ("/workspace/src/architecture/outer.zig", 22, True),
            source_points,
        )

    def test_ir_parser_keeps_unseen_block_lines_uncovered(self) -> None:
        llvm_ir_text = """
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
        source_points, instrumentation_point_count = LLVM_IR.coverage_points(
            llvm_ir_text,
            bytes([0b0000_0001]),
        )
        self.assertEqual(2, instrumentation_point_count)
        self.assertIn(
            ("/workspace/src/architecture/example.zig", 11, True),
            source_points,
        )
        self.assertIn(
            ("/workspace/src/architecture/example.zig", 21, False),
            source_points,
        )

    def test_ir_parser_rejects_missing_guard_arrays(self) -> None:
        with self.assertRaisesRegex(ValueError, "no sanitizer guard arrays"):
            LLVM_IR.coverage_points("define void @example() { ret void }", b"")

    def test_points_stream_is_versioned_and_records_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "coverage.points"
            COLLECT.write_points(path, "x86_64", 1, [("example.zig", 4, True)])
            self.assertEqual(
                "OS_ARCHITECTURE_COVERAGE_POINTS\t2\n"
                "architecture\tx86_64\n"
                "instrumentation_points\t1\n"
                "source_points\t1\n"
                "points\n"
                "example.zig\t4\t1\n",
                path.read_text(),
            )

    def test_ir_rewriter_removes_sanitizer_tls(self) -> None:
        source = (
            "@__sancov_lowest_stack = thread_local(initialexec) global i64 0\n"
        )
        rewritten = REWRITE_IR.rewrite(source, "x86_64")
        self.assertNotIn("thread_local", rewritten)

    def test_x86_32_rewriter_validates_bootstrap_sections(self) -> None:
        source = (
            '@__sancov_lowest_stack = thread_local(initialexec) global i32 0, section ".multiboot.data"\n'
            'define void @__sanitizer_cov_trace_pc_guard(ptr %guard) section ".multiboot.text" {\n'
            "  ret void\n"
            "}\n"
        )
        rewritten = REWRITE_IR.rewrite(source, "x86_32")
        self.assertNotIn("thread_local", rewritten)

    def test_x86_32_rewriter_rejects_normal_text_callback(self) -> None:
        source = (
            '@__sancov_lowest_stack = thread_local(initialexec) global i32 0, section ".multiboot.data"\n'
            'define void @__sanitizer_cov_trace_pc_guard(ptr %guard) section ".text" {\n'
            "  ret void\n"
            "}\n"
        )
        with self.assertRaisesRegex(ValueError, "bootstrap text"):
            REWRITE_IR.rewrite(source, "x86_32")

    def test_qemu_command_uses_direct_x86_32_kernel(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_32",
            image_kind="kernel",
            image=pathlib.Path("kernel.elf"),
            coverage_output=None,
        )
        command = ARCHITECTURE_TEST_RUNNER.build_command(
            arguments,
            pathlib.Path("serial.log"),
        )
        self.assertEqual("qemu-system-i386", command[0])
        self.assertEqual(["-kernel", "kernel.elf"], command[-2:])
        self.assertNotIn("isa-debugcon,iobase=0xe9,chardev=coverage0", command)

    def test_qemu_command_adds_coverage_channel(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_64",
            image_kind="cdrom",
            image=pathlib.Path("coverage.iso"),
            coverage_output=pathlib.Path("coverage.bin"),
        )
        command = ARCHITECTURE_TEST_RUNNER.build_command(
            arguments,
            pathlib.Path("serial.log"),
        )
        self.assertEqual("qemu-system-x86_64", command[0])
        self.assertIn("file,id=coverage0,path=coverage.bin", command)
        self.assertIn("isa-debugcon,iobase=0xe9,chardev=coverage0", command)
        self.assertEqual(["-cdrom", "coverage.iso"], command[-2:])

    def test_qemu_command_aggregates_multiboot_modules(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_32",
            image_kind="kernel",
            image=pathlib.Path("kernel.elf"),
            coverage_output=None,
            boot_module=[pathlib.Path("first.bin"), pathlib.Path("second.bin")],
        )
        command = ARCHITECTURE_TEST_RUNNER.build_command(
            arguments,
            pathlib.Path("serial.log"),
        )
        self.assertEqual(["-initrd", "first.bin,second.bin"], command[-2:])

    def test_qemu_command_rejects_modules_for_optical_disc(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_64",
            image_kind="cdrom",
            image=pathlib.Path("tests.iso"),
            coverage_output=None,
            boot_module=[pathlib.Path("module.bin")],
        )
        with self.assertRaisesRegex(ValueError, "direct kernel"):
            ARCHITECTURE_TEST_RUNNER.build_command(
                arguments,
                pathlib.Path("serial.log"),
            )

    def test_qemu_protocol_accepts_complete_success(self) -> None:
        summary = ARCHITECTURE_TEST_RUNNER.validate_protocol(
            "ordinary serial diagnostic\n"
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=2\n"
            'QEMU-TEST RUN id=first_test name="first test"\n'
            "QEMU-TEST PASS id=first_test\n"
            'QEMU-TEST RUN id=second_test name="second test"\n'
            "QEMU-TEST PASS id=second_test\n"
            "QEMU-TEST SUMMARY passed=2 failed=0\n",
            "x86_64",
        )
        self.assertEqual(2, summary.declared_tests)
        self.assertEqual(2, summary.passed)
        self.assertEqual(0, summary.failed)

    def test_qemu_protocol_rejects_wrong_architecture(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_32 mode=shared_machine tests=0\n"
            "QEMU-TEST SUMMARY passed=0 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "architecture mismatch"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_record_before_header(self) -> None:
        transcript = (
            'QEMU-TEST RUN id=test name="test"\n'
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=1\n"
            "QEMU-TEST PASS id=test\n"
            "QEMU-TEST SUMMARY passed=1 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "before protocol header"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_unknown_version(self) -> None:
        transcript = (
            "QEMU-TEST protocol=3 arch=x86_64 mode=shared_machine tests=0\n"
            "QEMU-TEST SUMMARY passed=0 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "protocol version"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_duplicate_result(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=1\n"
            'QEMU-TEST RUN id=test name="test"\n'
            "QEMU-TEST PASS id=test\n"
            "QEMU-TEST PASS id=test\n"
            "QEMU-TEST SUMMARY passed=1 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "duplicate test result"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_result_without_start(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=1\n"
            "QEMU-TEST PASS id=test\n"
            "QEMU-TEST SUMMARY passed=1 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "before start"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_missing_result(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=1\n"
            'QEMU-TEST RUN id=test name="test"\n'
            "QEMU-TEST SUMMARY passed=1 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "without results"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_contradictory_summary(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=1\n"
            'QEMU-TEST RUN id=test name="test"\n'
            "QEMU-TEST FAIL id=test error=ExpectationFailed\n"
            "QEMU-TEST SUMMARY passed=1 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "contradicts"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_malformed_record(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=1\n"
            "QEMU-TEST RUN broken\n"
            "QEMU-TEST SUMMARY passed=0 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "malformed"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_rejects_kernel_panic(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=0\n"
            'QEMU-TEST PANIC message="failure"\n'
        )
        with self.assertRaisesRegex(ValueError, "panicked"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(transcript, "x86_64")

    def test_qemu_protocol_accepts_authoritative_expected_fault(self) -> None:
        summary = ARCHITECTURE_TEST_RUNNER.validate_protocol(
            "QEMU-TEST protocol=2 arch=x86_64 mode=expected_fault tests=1\n"
            'QEMU-TEST RUN id=write_fault name="write fault"\n'
            "QEMU-TEST FAULT id=write_fault vector=14 error_code=0x3 "
            "instruction_pointer=0xffffffff80001234 cr2=0x4000 present=1 "
            "write=1 user=0 reserved=0 instruction_fetch=0\n",
            "x86_64",
            "expected_fault",
            "write_fault",
            14,
            0x7,
            0x3,
            0x4000,
        )
        self.assertTrue(summary.expected_fault_observed)
        self.assertEqual(1, summary.passed)

    def test_qemu_protocol_rejects_wrong_fault_vector(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=expected_fault tests=1\n"
            'QEMU-TEST RUN id=fault name="fault"\n'
            "QEMU-TEST FAULT id=fault vector=13 error_code=0x0 "
            "instruction_pointer=0x1000 cr2=0x0 present=0 write=0 user=0 "
            "reserved=0 instruction_fetch=0\n"
        )
        with self.assertRaisesRegex(ValueError, "vector mismatch"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(
                transcript,
                "x86_64",
                "expected_fault",
                "fault",
                14,
            )

    def test_qemu_protocol_rejects_fault_flag_disagreement(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=expected_fault tests=1\n"
            'QEMU-TEST RUN id=fault name="fault"\n'
            "QEMU-TEST FAULT id=fault vector=14 error_code=0x2 "
            "instruction_pointer=0x1000 cr2=0x2000 present=0 write=0 user=0 "
            "reserved=0 instruction_fetch=0\n"
        )
        with self.assertRaisesRegex(ValueError, "write flag"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(
                transcript,
                "x86_64",
                "expected_fault",
                "fault",
                14,
            )

    def test_qemu_protocol_rejects_summary_for_expected_fault(self) -> None:
        transcript = (
            "QEMU-TEST protocol=2 arch=x86_64 mode=expected_fault tests=1\n"
            'QEMU-TEST RUN id=fault name="fault"\n'
            "QEMU-TEST PASS id=fault\n"
            "QEMU-TEST SUMMARY passed=1 failed=0\n"
        )
        with self.assertRaisesRegex(ValueError, "terminate with a fault"):
            ARCHITECTURE_TEST_RUNNER.validate_protocol(
                transcript,
                "x86_64",
                "expected_fault",
                "fault",
                14,
            )


if __name__ == "__main__":
    unittest.main()