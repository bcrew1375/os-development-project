#!/usr/bin/env python3

import argparse
import datetime
import pathlib
import re


TOTAL_PATTERN = re.compile(
    r"^TOTAL\s+(?P<covered>\d+)\s+(?P<coverable>\d+)\s+(?P<percentage>\d+\.\d+)%",
    re.MULTILINE,
)
PHYSICAL_HEADER_PATTERN = re.compile(r"^QEMU-TEST protocol=\d+ .* tests=(\d+)$", re.MULTILINE)
ZIG_TEST_TOTAL_PATTERN = re.compile(r"(?:^|\n)(\d+)/(\d+) [^\n]+\.\.\.(?:OK|SKIP)")
PYTHON_TEST_PATTERN = re.compile(r"^\s*def test_", re.MULTILINE)
ZIG_TEST_PATTERN = re.compile(r'^\s*test\s+"', re.MULTILINE)


def read(path: pathlib.Path) -> str:
    return path.read_text(errors="replace")


def coverage_total(text: str) -> tuple[int, int, str]:
    matches = list(TOTAL_PATTERN.finditer(text))
    if not matches:
        raise ValueError("coverage log is missing a TOTAL row")
    match = matches[-1]
    return (
        int(match.group("covered")),
        int(match.group("coverable")),
        match.group("percentage"),
    )


def native_test_count(text: str) -> int:
    totals = [int(match.group(2)) for match in ZIG_TEST_TOTAL_PATTERN.finditer(text)]
    if not totals:
        raise ValueError("native coverage log is missing Zig test progress")
    return max(totals)


def physical_test_count(text: str) -> int:
    counts = [int(value) for value in PHYSICAL_HEADER_PATTERN.findall(text)]
    if not counts:
        raise ValueError("architecture test log is missing protocol headers")
    return sum(counts)


def source_test_count(paths: list[pathlib.Path], pattern: re.Pattern[str]) -> int:
    return sum(len(pattern.findall(read(path))) for path in paths)


def smoke_status(text: str) -> str:
    return "pass" if "SYSTEM-SMOKE EXIT status=0" in text else "fail"


def create_report(arguments: argparse.Namespace) -> str:
    common_text = read(arguments.common_coverage)
    architecture_32_text = read(arguments.architecture_coverage_x86_32)
    architecture_64_text = read(arguments.architecture_coverage_x86_64)
    physical_32_text = read(arguments.architecture_tests_x86_32)
    physical_64_text = read(arguments.architecture_tests_x86_64)

    common = coverage_total(common_text)
    architecture_32 = coverage_total(architecture_32_text)
    architecture_64 = coverage_total(architecture_64_text)
    host_count = source_test_count(arguments.host_test_sources, PYTHON_TEST_PATTERN)
    abi_count = source_test_count(arguments.abi_test_sources, ZIG_TEST_PATTERN)
    root_task_count = source_test_count(arguments.root_task_test_sources, ZIG_TEST_PATTERN)

    return f"""# Test and coverage trend

- Date: {arguments.date.isoformat()}
- Commit: `{arguments.commit}`

| Metric | Result |
| --- | ---: |
| Native kernel Zig tests | {native_test_count(common_text)} |
| Host Python tooling tests | {host_count} |
| ABI library tests | {abi_count} |
| Root-task tests | {root_task_count} |
| x86-32 physical tests | {physical_test_count(physical_32_text)} |
| x86-64 physical tests | {physical_test_count(physical_64_text)} |
| Common emitted-line coverage | {common[2]}% ({common[0]}/{common[1]}) |
| x86-32 emitted architecture coverage | {architecture_32[2]}% ({architecture_32[0]}/{architecture_32[1]}) |
| x86-64 emitted architecture coverage | {architecture_64[2]}% ({architecture_64[0]}/{architecture_64[1]}) |
| x86-32 production system smoke | {smoke_status(read(arguments.system_smoke_x86_32))} |
| x86-64 production system smoke | {smoke_status(read(arguments.system_smoke_x86_64))} |

Coverage values are measurements only; this report does not enforce thresholds.
"""


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", type=datetime.date.fromisoformat, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--common-coverage", type=pathlib.Path, required=True)
    parser.add_argument("--architecture-coverage-x86-32", type=pathlib.Path, required=True)
    parser.add_argument("--architecture-coverage-x86-64", type=pathlib.Path, required=True)
    parser.add_argument("--architecture-tests-x86-32", type=pathlib.Path, required=True)
    parser.add_argument("--architecture-tests-x86-64", type=pathlib.Path, required=True)
    parser.add_argument("--system-smoke-x86-32", type=pathlib.Path, required=True)
    parser.add_argument("--system-smoke-x86-64", type=pathlib.Path, required=True)
    parser.add_argument("--host-test-source", dest="host_test_sources", action="append", type=pathlib.Path, required=True)
    parser.add_argument("--abi-test-source", dest="abi_test_sources", action="append", type=pathlib.Path, required=True)
    parser.add_argument("--root-task-test-source", dest="root_task_test_sources", action="append", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(create_report(arguments))


if __name__ == "__main__":
    main()