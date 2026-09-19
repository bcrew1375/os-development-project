#!/usr/bin/env python3

import datetime
import importlib.util
import pathlib
import sys
import tempfile
import types
import unittest


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_reporter():
    path = ROOT / "tools/test_trend_report.py"
    spec = importlib.util.spec_from_file_location("test_trend_report", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


REPORTER = load_reporter()


class TestTrendReportTests(unittest.TestCase):
    def test_report_combines_counts_coverage_and_smoke_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            directory = pathlib.Path(directory_name)

            def write(name: str, text: str) -> pathlib.Path:
                path = directory / name
                path.write_text(text)
                return path

            arguments = types.SimpleNamespace(
                date=datetime.date(2026, 9, 19),
                commit="abc123",
                common_coverage=write(
                    "common.log",
                    "1/2 first...OK\n2/2 second...OK\nTOTAL 9 10 90.00%\n",
                ),
                architecture_coverage_x86_32=write("coverage32.log", "TOTAL 7 10 70.00%\n"),
                architecture_coverage_x86_64=write("coverage64.log", "TOTAL 8 10 80.00%\n"),
                architecture_tests_x86_32=write(
                    "tests32.log",
                    "QEMU-TEST protocol=2 arch=x86_32 mode=shared_machine tests=3\n",
                ),
                architecture_tests_x86_64=write(
                    "tests64.log",
                    "QEMU-TEST protocol=2 arch=x86_64 mode=shared_machine tests=4\n",
                ),
                system_smoke_x86_32=write("smoke32.log", "SYSTEM-SMOKE EXIT status=0\n"),
                system_smoke_x86_64=write("smoke64.log", "SYSTEM-SMOKE EXIT status=1\n"),
                host_test_sources=[write("host.py", "def test_one():\n    pass\n")],
                abi_test_sources=[write("abi.zig", 'test "one" {}\n')],
                root_task_test_sources=[write("root.zig", 'test "one" {}\ntest "two" {}\n')],
            )
            report = REPORTER.create_report(arguments)

        self.assertIn("Date: 2026-09-19", report)
        self.assertIn("Native kernel Zig tests | 2", report)
        self.assertIn("x86-32 physical tests | 3", report)
        self.assertIn("Common emitted-line coverage | 90.00% (9/10)", report)
        self.assertIn("x86-32 production system smoke | pass", report)
        self.assertIn("x86-64 production system smoke | fail", report)
        self.assertIn("does not enforce thresholds", report)

    def test_coverage_total_requires_a_total_row(self) -> None:
        with self.assertRaisesRegex(ValueError, "TOTAL"):
            REPORTER.coverage_total("no report")


if __name__ == "__main__":
    unittest.main()