#!/usr/bin/env python3

import argparse
import dataclasses
import pathlib
import re
import subprocess
import sys
import tempfile


SUCCESS_EXIT_STATUS = 1
TEST_FAILURE_EXIT_STATUS = 3
PROTOCOL_VERSION = 1

HEADER_PATTERN = re.compile(
    r"^QEMU-TEST protocol=(?P<version>\d+) "
    r"arch=(?P<architecture>\S+) tests=(?P<count>\d+)$"
)
RUN_PATTERN = re.compile(r'^QEMU-TEST RUN name="(?P<name>[^"]+)"$')
PASS_PATTERN = re.compile(r'^QEMU-TEST PASS name="(?P<name>[^"]+)"$')
FAIL_PATTERN = re.compile(
    r'^QEMU-TEST FAIL name="(?P<name>[^"]+)" error=(?P<error>\S+)$'
)
SUMMARY_PATTERN = re.compile(
    r"^QEMU-TEST SUMMARY passed=(?P<passed>\d+) failed=(?P<failed>\d+)$"
)


@dataclasses.dataclass(frozen=True)
class ProtocolSummary:
    declared_tests: int
    passed: int
    failed: int


def validate_protocol(transcript: str, expected_architecture: str) -> ProtocolSummary:
    header = None
    summary = None
    started: set[str] = set()
    results: dict[str, str] = {}

    for line in transcript.splitlines():
        if not line.startswith("QEMU-TEST"):
            continue

        if match := HEADER_PATTERN.fullmatch(line):
            if header is not None:
                raise ValueError("duplicate QEMU-TEST protocol header")
            header = match
            continue

        if header is None:
            raise ValueError("QEMU-TEST record appears before protocol header")

        if match := RUN_PATTERN.fullmatch(line):
            name = match.group("name")
            if name in started:
                raise ValueError(f'duplicate test start: "{name}"')
            if summary is not None:
                raise ValueError("test start appears after QEMU-TEST summary")
            started.add(name)
            continue

        result_match = PASS_PATTERN.fullmatch(line) or FAIL_PATTERN.fullmatch(line)
        if result_match:
            name = result_match.group("name")
            if name not in started:
                raise ValueError(f'test result appears before start: "{name}"')
            if name in results:
                raise ValueError(f'duplicate test result: "{name}"')
            if summary is not None:
                raise ValueError("test result appears after QEMU-TEST summary")
            results[name] = "pass" if PASS_PATTERN.fullmatch(line) else "fail"
            continue

        if match := SUMMARY_PATTERN.fullmatch(line):
            if summary is not None:
                raise ValueError("duplicate QEMU-TEST summary")
            summary = match
            continue

        if line.startswith("QEMU-TEST PANIC"):
            raise ValueError("architecture test kernel panicked")
        if line.startswith("QEMU-TEST COVERAGE-FAIL"):
            raise ValueError("architecture coverage capture failed")
        raise ValueError(f"malformed QEMU-TEST record: {line}")

    if header is None:
        raise ValueError("missing QEMU-TEST protocol header")
    if summary is None:
        raise ValueError("missing QEMU-TEST summary")

    version = int(header.group("version"))
    architecture = header.group("architecture")
    declared_tests = int(header.group("count"))
    passed = int(summary.group("passed"))
    failed = int(summary.group("failed"))

    if version != PROTOCOL_VERSION:
        raise ValueError(f"unsupported QEMU-TEST protocol version: {version}")
    if architecture != expected_architecture:
        raise ValueError(
            "QEMU-TEST architecture mismatch: "
            f"expected {expected_architecture}, observed {architecture}"
        )
    if len(started) != declared_tests:
        raise ValueError(
            "QEMU-TEST declared test count does not match starts: "
            f"declared {declared_tests}, observed {len(started)}"
        )
    if set(results) != started:
        missing = sorted(started - set(results))
        raise ValueError(f"tests without results: {', '.join(missing)}")

    observed_passed = sum(result == "pass" for result in results.values())
    observed_failed = sum(result == "fail" for result in results.values())
    if passed != observed_passed or failed != observed_failed:
        raise ValueError(
            "QEMU-TEST summary contradicts individual results: "
            f"summary {passed} passed/{failed} failed, "
            f"observed {observed_passed} passed/{observed_failed} failed"
        )
    if passed + failed != declared_tests:
        raise ValueError("QEMU-TEST summary total does not match declared test count")

    return ProtocolSummary(declared_tests=declared_tests, passed=passed, failed=failed)


def qemu_executable(architecture: str) -> str:
    return {
        "x86_32": "qemu-system-i386",
        "x86_64": "qemu-system-x86_64",
    }[architecture]


def build_command(arguments: argparse.Namespace, serial_log: pathlib.Path) -> list[str]:
    command = [
        qemu_executable(arguments.architecture),
        "-display",
        "none",
        "-monitor",
        "none",
        "-chardev",
        f"file,id=serial0,path={serial_log}",
        "-serial",
        "chardev:serial0",
    ]
    if arguments.coverage_output:
        command.extend(
            [
                "-chardev",
                f"file,id=coverage0,path={arguments.coverage_output}",
                "-device",
                "isa-debugcon,iobase=0xe9,chardev=coverage0",
            ]
        )
    command.extend(
        [
            "-m",
            "128M",
            "-M",
            "pc,accel=tcg,smm=off",
            "-no-reboot",
            "-no-shutdown",
            "-device",
            "isa-debug-exit,iobase=0xf4,iosize=0x04",
            f"-{arguments.image_kind}",
            str(arguments.image),
        ]
    )
    return command


def run(arguments: argparse.Namespace) -> int:
    with tempfile.NamedTemporaryFile() as serial_log_file:
        serial_log = pathlib.Path(serial_log_file.name)
        command = build_command(arguments, serial_log)
        print(
            "Launching architecture tests with "
            f"{command[0]} ({arguments.image_kind}: {arguments.image})",
            file=sys.stderr,
        )
        try:
            completed = subprocess.run(command, timeout=arguments.timeout_seconds)
        except subprocess.TimeoutExpired:
            print(serial_log.read_text(errors="replace"), end="")
            print(
                f"architecture tests timed out after {arguments.timeout_seconds} seconds",
                file=sys.stderr,
            )
            return 1

        transcript = serial_log.read_text(errors="replace")
        print(transcript, end="")
        try:
            protocol_summary = validate_protocol(transcript, arguments.architecture)
        except ValueError as error:
            print(f"invalid architecture test protocol: {error}", file=sys.stderr)
            return 1

        if completed.returncode == SUCCESS_EXIT_STATUS:
            if protocol_summary.failed != 0:
                print(
                    "QEMU exited successfully despite protocol test failures",
                    file=sys.stderr,
                )
                return 1
            return 0
        if completed.returncode == TEST_FAILURE_EXIT_STATUS:
            print("architecture test suite reported failure", file=sys.stderr)
        else:
            print(
                "QEMU terminated without a valid test result "
                f"(status {completed.returncode})",
                file=sys.stderr,
            )
        return 1


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", choices=("x86_32", "x86_64"), required=True)
    parser.add_argument("--image-kind", choices=("kernel", "cdrom"), required=True)
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--coverage-output", type=pathlib.Path)
    arguments = parser.parse_args()
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be greater than zero")
    return arguments


if __name__ == "__main__":
    raise SystemExit(run(parse_arguments()))