#!/usr/bin/env python3

import argparse
import dataclasses
import json
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time


PROTOCOL_VERSION = 3
PREFIX = "SYSTEM-SMOKE"
HEADER = f"{PREFIX} protocol={PROTOCOL_VERSION}"
MILESTONES = (
    "root_process_prepared",
    "kernel_initialized",
    "userspace_entered",
    "boot_info_validated",
    "boot_modules_validated",
    "physical_memory_allocated",
    "address_space_capability_acquired",
    "memory_object_capability_acquired",
    "memory_object_mapped",
    "userspace_heap_verified",
    "cooperative_yield_completed",
    "clean_child_started",
    "clean_child_yielding",
    "root_resumed_after_clean_child_yield",
    "clean_child_resumed",
    "clean_child_destroyed",
    "fault_child_started",
    "fault_child_yielding",
    "root_resumed_after_fault_child_yield",
    "fault_child_resumed",
    "fault_child_destroyed",
    "root_resumed_after_children",
)
MILESTONE_PATTERN = re.compile(r"^SYSTEM-SMOKE milestone=(?P<name>[a-z0-9_]+)$")
CHILD_EXIT_PATTERN = re.compile(r"^SYSTEM-SMOKE CHILD_EXIT status=(?P<status>\d+)$")
CHILD_FAULT_PATTERN = re.compile(r"^SYSTEM-SMOKE CHILD_FAULT kind=(?P<kind>[a-z0-9_]+)$")
EXIT_PATTERN = re.compile(r"^SYSTEM-SMOKE EXIT status=(?P<status>\d+)$")

EXPECTED_EVENTS = (
    *(f"milestone={milestone}" for milestone in MILESTONES[:15]),
    "child_exit=0",
    f"milestone={MILESTONES[15]}",
    *(f"milestone={milestone}" for milestone in MILESTONES[16:20]),
    "child_fault=invalid_opcode",
    *(f"milestone={milestone}" for milestone in MILESTONES[20:]),
    "root_exit",
)


@dataclasses.dataclass(frozen=True)
class ProtocolResult:
    exit_status: int


def validate_protocol(transcript: str) -> ProtocolResult:
    protocol_lines = [line for line in transcript.splitlines() if line.startswith(PREFIX)]
    if not protocol_lines:
        raise ValueError("missing SYSTEM-SMOKE protocol header")
    if protocol_lines[0] != HEADER:
        if protocol_lines[0].startswith(f"{PREFIX} protocol="):
            raise ValueError(f"unsupported SYSTEM-SMOKE protocol header: {protocol_lines[0]}")
        raise ValueError("SYSTEM-SMOKE record appears before protocol header")

    expected_index = 0
    exit_status = None
    for line in protocol_lines[1:]:
        if line == HEADER:
            raise ValueError("duplicate SYSTEM-SMOKE protocol header")
        if exit_status is not None:
            raise ValueError("SYSTEM-SMOKE record appears after EXIT")

        observed, root_status = parse_event(line)
        if expected_index >= len(EXPECTED_EVENTS):
            raise ValueError(f"unexpected SYSTEM-SMOKE record: {line}")
        expected = EXPECTED_EVENTS[expected_index]
        if observed != expected:
            raise ValueError(
                f"out-of-order SYSTEM-SMOKE record: expected {expected}, observed {observed}"
            )
        expected_index += 1
        if root_status is not None:
            exit_status = root_status

    if expected_index != len(EXPECTED_EVENTS):
        raise ValueError(f"missing SYSTEM-SMOKE record: {EXPECTED_EVENTS[expected_index]}")
    if exit_status is None:
        raise ValueError("missing SYSTEM-SMOKE EXIT record")
    return ProtocolResult(exit_status=exit_status)


def parse_event(line: str) -> tuple[str, int | None]:
    if match := MILESTONE_PATTERN.fullmatch(line):
        milestone = match.group("name")
        if milestone not in MILESTONES:
            raise ValueError(f"unknown SYSTEM-SMOKE milestone: {milestone}")
        return f"milestone={milestone}", None
    if match := CHILD_EXIT_PATTERN.fullmatch(line):
        return f"child_exit={int(match.group('status'))}", None
    if match := CHILD_FAULT_PATTERN.fullmatch(line):
        return f"child_fault={match.group('kind')}", None
    if match := EXIT_PATTERN.fullmatch(line):
        return "root_exit", int(match.group("status"))
    raise ValueError(f"malformed SYSTEM-SMOKE record: {line}")


def qemu_executable(architecture: str) -> str:
    return {
        "x86_32": "qemu-system-i386",
        "x86_64": "qemu-system-x86_64",
    }[architecture]


def build_command(
    arguments: argparse.Namespace,
    serial_log: pathlib.Path,
    qmp_socket: pathlib.Path,
) -> list[str]:
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
        "-qmp",
        f"unix:{qmp_socket},server=on,wait=off",
        "-m",
        "128M",
        "-M",
        "pc,accel=tcg,smm=off",
        "-no-reboot",
        "-no-shutdown",
    ]
    if arguments.image_kind == "cdrom":
        if arguments.boot_module is not None:
            raise ValueError("boot modules are only valid with direct kernel images")
        command.extend(["-boot", "d", "-cdrom", str(arguments.image)])
    else:
        if not arguments.boot_module:
            raise ValueError("direct kernel images require a root-task boot module")
        for boot_module in arguments.boot_module:
            if "," in str(boot_module):
                raise ValueError("boot module paths must not contain commas")
        command.extend(
            [
                "-kernel",
                str(arguments.image),
                "-initrd",
                ",".join(str(module) for module in arguments.boot_module),
            ]
        )
    return command


class QmpClient:
    def __init__(self, path: pathlib.Path, deadline: float):
        self.path = path
        self.deadline = deadline
        self.connection: socket.socket | None = None
        self.reader = None

    def __enter__(self):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        while True:
            try:
                connection.connect(str(self.path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= self.deadline:
                    connection.close()
                    raise TimeoutError("timed out connecting to QEMU QMP socket")
                time.sleep(0.01)
        connection.settimeout(max(0.1, self.deadline - time.monotonic()))
        self.connection = connection
        self.reader = connection.makefile("rb")
        greeting = self._read_message()
        if "QMP" not in greeting:
            raise RuntimeError("QMP greeting is missing the QMP field")
        self._execute("qmp_capabilities")
        return self

    def __exit__(self, _exception_type, _exception, _traceback):
        if self.reader is not None:
            self.reader.close()
        if self.connection is not None:
            self.connection.close()

    def quit(self) -> None:
        self._execute("quit")

    def _execute(self, command: str) -> None:
        assert self.connection is not None
        payload = json.dumps({"execute": command}).encode() + b"\r\n"
        self.connection.sendall(payload)
        while True:
            response = self._read_message()
            if "event" in response:
                continue
            if "error" in response:
                raise RuntimeError(f"QMP {command} failed: {response['error']}")
            if "return" not in response:
                raise RuntimeError(f"QMP {command} returned an invalid response")
            return

    def _read_message(self) -> dict:
        assert self.reader is not None
        line = self.reader.readline()
        if not line:
            raise RuntimeError("QMP connection closed unexpectedly")
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("QMP returned malformed JSON") from error
        if not isinstance(message, dict):
            raise RuntimeError("QMP returned a non-object message")
        return message


def read_transcript(path: pathlib.Path) -> str:
    try:
        return path.read_text(errors="replace")
    except FileNotFoundError:
        return ""


def has_complete_exit_record(transcript: str) -> bool:
    for line in transcript.splitlines(keepends=True):
        if not line.endswith(("\n", "\r")):
            continue
        if EXIT_PATTERN.fullmatch(line.rstrip("\r\n")):
            return True
    return False


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run(arguments: argparse.Namespace) -> int:
    serial_log = arguments.transcript_output
    serial_log.parent.mkdir(parents=True, exist_ok=True)
    serial_log.write_text("")

    with tempfile.TemporaryDirectory(prefix="system-smoke-") as temporary_directory:
        qmp_socket = pathlib.Path(temporary_directory) / "qmp.sock"
        try:
            command = build_command(arguments, serial_log, qmp_socket)
        except ValueError as error:
            print(f"invalid system smoke configuration: {error}", file=sys.stderr)
            return 1

        print(
            f"Launching production system smoke test with {command[0]} "
            f"({arguments.image_kind}: {arguments.image})",
            file=sys.stderr,
        )
        process = subprocess.Popen(command)
        deadline = time.monotonic() + arguments.timeout_seconds
        protocol_result = None
        failure = None

        try:
            while time.monotonic() < deadline:
                transcript = read_transcript(serial_log)
                if has_complete_exit_record(transcript):
                    try:
                        protocol_result = validate_protocol(transcript)
                    except ValueError as error:
                        failure = f"invalid system smoke protocol: {error}"
                        break
                    try:
                        with QmpClient(qmp_socket, deadline) as qmp:
                            qmp.quit()
                    except (OSError, RuntimeError, TimeoutError) as error:
                        failure = f"failed to terminate QEMU through QMP: {error}"
                    break

                return_code = process.poll()
                if return_code is not None:
                    failure = f"QEMU exited before protocol completion with status {return_code}"
                    break
                time.sleep(0.01)
            else:
                failure = f"system smoke test timed out after {arguments.timeout_seconds} seconds"

            if failure is not None:
                stop_process(process)
            else:
                try:
                    return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    failure = "QEMU did not exit after the QMP quit command"
                    stop_process(process)
                else:
                    if return_code != 0:
                        failure = f"QEMU returned status {return_code} after QMP quit"
        finally:
            stop_process(process)

        transcript = read_transcript(serial_log)
        print(transcript, end="")
        if failure is not None:
            if protocol_result is None:
                try:
                    validate_protocol(transcript)
                except ValueError as error:
                    print(f"last completed stage: {last_completed_stage(transcript)}", file=sys.stderr)
                    print(f"protocol detail: {error}", file=sys.stderr)
            print(failure, file=sys.stderr)
            return 1
        assert protocol_result is not None
        if protocol_result.exit_status != 0:
            print(
                f"root task reported nonzero exit status {protocol_result.exit_status}",
                file=sys.stderr,
            )
            return 1
        return 0


def last_completed_stage(transcript: str) -> str:
    completed = "none"
    for line in transcript.splitlines():
        if line == HEADER:
            completed = "protocol_header"
        elif match := MILESTONE_PATTERN.fullmatch(line):
            if match.group("name") in MILESTONES:
                completed = match.group("name")
        elif CHILD_EXIT_PATTERN.fullmatch(line):
            completed = "child_exit"
        elif CHILD_FAULT_PATTERN.fullmatch(line):
            completed = "child_fault"
        elif EXIT_PATTERN.fullmatch(line):
            completed = "exit"
    return completed


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", choices=("x86_32", "x86_64"), required=True)
    parser.add_argument("--image-kind", choices=("kernel", "cdrom"), required=True)
    parser.add_argument("--image", type=pathlib.Path, required=True)
    parser.add_argument("--boot-module", type=pathlib.Path, action="append")
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--transcript-output", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be greater than zero")
    return arguments


if __name__ == "__main__":
    raise SystemExit(run(parse_arguments()))