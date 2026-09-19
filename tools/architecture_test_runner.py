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
PROTOCOL_VERSION = 2
EXECUTION_MODES = ("shared_machine", "isolated_machine", "expected_fault")

HEADER_PATTERN = re.compile(
    r"^QEMU-TEST protocol=(?P<version>\d+) "
    r"arch=(?P<architecture>\S+) mode=(?P<mode>\S+) tests=(?P<count>\d+)$"
)
RUN_PATTERN = re.compile(
    r'^QEMU-TEST RUN id=(?P<id>\S+) name="(?P<name>[^"]+)"$'
)
PASS_PATTERN = re.compile(r"^QEMU-TEST PASS id=(?P<id>\S+)$")
FAIL_PATTERN = re.compile(
    r"^QEMU-TEST FAIL id=(?P<id>\S+) error=(?P<error>\S+)$"
)
FAULT_PATTERN = re.compile(
    r"^QEMU-TEST FAULT id=(?P<id>\S+) vector=(?P<vector>\d+) "
    r"error_code=(?P<error_code>0x[0-9a-fA-F]+) "
    r"instruction_pointer=(?P<instruction_pointer>0x[0-9a-fA-F]+) "
    r"cr2=(?P<cr2>0x[0-9a-fA-F]+) present=(?P<present>[01]) "
    r"write=(?P<write>[01]) user=(?P<user>[01]) reserved=(?P<reserved>[01]) "
    r"instruction_fetch=(?P<instruction_fetch>[01])$"
)
SUMMARY_PATTERN = re.compile(
    r"^QEMU-TEST SUMMARY passed=(?P<passed>\d+) failed=(?P<failed>\d+)$"
)


@dataclasses.dataclass(frozen=True)
class ProtocolSummary:
    declared_tests: int
    passed: int
    failed: int
    expected_fault_observed: bool = False


def validate_protocol(
    transcript: str,
    expected_architecture: str,
    expected_mode: str = "shared_machine",
    expected_test_id: str | None = None,
    expected_vector: int | None = None,
    expected_error_code_mask: int = 0,
    expected_error_code_value: int = 0,
    expected_cr2: int | None = None,
) -> ProtocolSummary:
    header = None
    summary = None
    started: set[str] = set()
    results: dict[str, str] = {}
    fault = None

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
            test_id = match.group("id")
            if test_id in started:
                raise ValueError(f"duplicate test start: {test_id}")
            if summary is not None:
                raise ValueError("test start appears after QEMU-TEST summary")
            if fault is not None:
                raise ValueError("test start appears after QEMU-TEST fault")
            started.add(test_id)
            continue

        result_match = PASS_PATTERN.fullmatch(line) or FAIL_PATTERN.fullmatch(line)
        if result_match:
            test_id = result_match.group("id")
            if test_id not in started:
                raise ValueError(f"test result appears before start: {test_id}")
            if test_id in results:
                raise ValueError(f"duplicate test result: {test_id}")
            if summary is not None:
                raise ValueError("test result appears after QEMU-TEST summary")
            if fault is not None:
                raise ValueError("test result appears after QEMU-TEST fault")
            results[test_id] = "pass" if PASS_PATTERN.fullmatch(line) else "fail"
            continue

        if match := FAULT_PATTERN.fullmatch(line):
            if fault is not None:
                raise ValueError("duplicate QEMU-TEST fault")
            if summary is not None:
                raise ValueError("fault appears after QEMU-TEST summary")
            fault = match
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
        if line.startswith("QEMU-TEST UNEXPECTED-FAULT"):
            raise ValueError("architecture test observed an unexpected fault")
        raise ValueError(f"malformed QEMU-TEST record: {line}")

    if header is None:
        raise ValueError("missing QEMU-TEST protocol header")
    version = int(header.group("version"))
    architecture = header.group("architecture")
    mode = header.group("mode")
    declared_tests = int(header.group("count"))

    if version != PROTOCOL_VERSION:
        raise ValueError(f"unsupported QEMU-TEST protocol version: {version}")
    if architecture != expected_architecture:
        raise ValueError(
            "QEMU-TEST architecture mismatch: "
            f"expected {expected_architecture}, observed {architecture}"
        )
    if mode != expected_mode:
        raise ValueError(
            f"QEMU-TEST execution mode mismatch: expected {expected_mode}, observed {mode}"
        )
    if expected_test_id is not None and started != {expected_test_id}:
        raise ValueError(
            "QEMU-TEST selected test mismatch: "
            f"expected {expected_test_id}, observed {', '.join(sorted(started))}"
        )
    if len(started) != declared_tests:
        raise ValueError(
            "QEMU-TEST declared test count does not match starts: "
            f"declared {declared_tests}, observed {len(started)}"
        )
    if mode == "expected_fault":
        return validate_expected_fault(
            fault,
            started,
            results,
            summary,
            declared_tests,
            expected_test_id,
            expected_vector,
            expected_error_code_mask,
            expected_error_code_value,
            expected_cr2,
        )

    if fault is not None:
        raise ValueError("fault record is only valid in expected_fault mode")
    if summary is None:
        raise ValueError("missing QEMU-TEST summary")
    if set(results) != started:
        missing = sorted(started - set(results))
        raise ValueError(f"tests without results: {', '.join(missing)}")

    passed = int(summary.group("passed"))
    failed = int(summary.group("failed"))
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


def validate_expected_fault(
    fault,
    started: set[str],
    results: dict[str, str],
    summary,
    declared_tests: int,
    expected_test_id: str | None,
    expected_vector: int | None,
    expected_error_code_mask: int,
    expected_error_code_value: int,
    expected_cr2: int | None,
) -> ProtocolSummary:
    if declared_tests != 1:
        raise ValueError("expected_fault mode must declare exactly one test")
    if results or summary is not None:
        raise ValueError("expected_fault mode must terminate with a fault record")
    if fault is None:
        raise ValueError("missing QEMU-TEST fault")

    test_id = fault.group("id")
    if test_id not in started:
        raise ValueError("fault appears before matching test start")
    if expected_test_id is not None and test_id != expected_test_id:
        raise ValueError("QEMU-TEST fault test identifier mismatch")
    if expected_vector is None:
        raise ValueError("expected fault vector was not configured")

    vector = int(fault.group("vector"))
    error_code = int(fault.group("error_code"), 16)
    instruction_pointer = int(fault.group("instruction_pointer"), 16)
    cr2 = int(fault.group("cr2"), 16)
    if vector != expected_vector:
        raise ValueError(f"fault vector mismatch: expected {expected_vector}, observed {vector}")
    if error_code & expected_error_code_mask != expected_error_code_value:
        raise ValueError("fault error code does not match expected mask and value")
    if expected_cr2 is not None and cr2 != expected_cr2:
        raise ValueError(f"fault CR2 mismatch: expected {expected_cr2:#x}, observed {cr2:#x}")
    if instruction_pointer == 0:
        raise ValueError("fault instruction pointer must be nonzero")

    decoded_bits = {
        "present": 0x01,
        "write": 0x02,
        "user": 0x04,
        "reserved": 0x08,
        "instruction_fetch": 0x10,
    }
    for field, bit in decoded_bits.items():
        if int(fault.group(field)) != int((error_code & bit) != 0):
            raise ValueError(f"fault {field} flag contradicts the error code")

    return ProtocolSummary(
        declared_tests=declared_tests,
        passed=1,
        failed=0,
        expected_fault_observed=True,
    )


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
    boot_modules = getattr(arguments, "boot_module", [])
    if boot_modules:
        if arguments.image_kind != "kernel":
            raise ValueError("boot modules are only valid with direct kernel images")
        if any("," in str(path) for path in boot_modules):
            raise ValueError("boot module paths must not contain commas")
        command.extend(["-initrd", ",".join(map(str, boot_modules))])
    return command


def run(arguments: argparse.Namespace) -> int:
    with tempfile.NamedTemporaryFile() as serial_log_file:
        serial_log = pathlib.Path(serial_log_file.name)
        try:
            command = build_command(arguments, serial_log)
        except ValueError as error:
            print(f"invalid architecture test configuration: {error}", file=sys.stderr)
            return 1
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
            protocol_summary = validate_protocol(
                transcript,
                arguments.architecture,
                arguments.execution_mode,
                arguments.test_id,
                arguments.expected_vector,
                arguments.expected_error_code_mask,
                arguments.expected_error_code_value,
                arguments.expected_cr2,
            )
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
    parser.add_argument("--execution-mode", choices=EXECUTION_MODES, required=True)
    parser.add_argument("--test-id")
    parser.add_argument("--expected-vector", type=int)
    parser.add_argument("--expected-error-code-mask", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--expected-error-code-value", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--expected-cr2", type=lambda value: int(value, 0))
    parser.add_argument("--coverage-output", type=pathlib.Path)
    parser.add_argument("--boot-module", action="append", type=pathlib.Path, default=[])
    arguments = parser.parse_args()
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be greater than zero")
    if arguments.execution_mode == "shared_machine" and arguments.test_id is not None:
        parser.error("--test-id is invalid for shared_machine mode")
    if arguments.execution_mode != "shared_machine" and arguments.test_id is None:
        parser.error("--test-id is required for isolated execution modes")
    if arguments.execution_mode == "expected_fault" and arguments.expected_vector is None:
        parser.error("--expected-vector is required for expected_fault mode")
    return arguments


if __name__ == "__main__":
    raise SystemExit(run(parse_arguments()))