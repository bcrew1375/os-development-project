#!/usr/bin/env python3

import importlib.util
import pathlib
import sys
import types
import unittest


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_runner():
    path = ROOT / "tools/system_smoke_runner.py"
    spec = importlib.util.spec_from_file_location("system_smoke_runner", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


RUNNER = load_runner()


def valid_transcript(exit_status: int = 0) -> str:
    records = [RUNNER.HEADER]
    records.extend(f"{RUNNER.PREFIX} milestone={name}" for name in RUNNER.MILESTONES)
    records.append(f"{RUNNER.PREFIX} EXIT status={exit_status}")
    return "ordinary diagnostic\n" + "\n".join(records) + "\n"


class SystemSmokeRunnerTests(unittest.TestCase):
    def test_protocol_accepts_complete_ordered_success(self) -> None:
        result = RUNNER.validate_protocol(valid_transcript())
        self.assertEqual(0, result.exit_status)

    def test_protocol_preserves_nonzero_guest_exit(self) -> None:
        result = RUNNER.validate_protocol(valid_transcript(7))
        self.assertEqual(7, result.exit_status)

    def test_protocol_rejects_missing_header(self) -> None:
        with self.assertRaisesRegex(ValueError, "header"):
            RUNNER.validate_protocol("ordinary diagnostic\n")

    def test_protocol_rejects_duplicate_header(self) -> None:
        transcript = valid_transcript().replace(
            RUNNER.HEADER,
            f"{RUNNER.HEADER}\n{RUNNER.HEADER}",
            1,
        )
        with self.assertRaisesRegex(ValueError, "duplicate"):
            RUNNER.validate_protocol(transcript)

    def test_protocol_rejects_duplicate_milestone(self) -> None:
        record = f"{RUNNER.PREFIX} milestone={RUNNER.MILESTONES[0]}"
        transcript = valid_transcript().replace(record, f"{record}\n{record}", 1)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            RUNNER.validate_protocol(transcript)

    def test_protocol_rejects_out_of_order_milestone(self) -> None:
        first = f"{RUNNER.PREFIX} milestone={RUNNER.MILESTONES[0]}"
        second = f"{RUNNER.PREFIX} milestone={RUNNER.MILESTONES[1]}"
        transcript = valid_transcript().replace(f"{first}\n{second}", f"{second}\n{first}")
        with self.assertRaisesRegex(ValueError, "out-of-order"):
            RUNNER.validate_protocol(transcript)

    def test_protocol_rejects_malformed_record(self) -> None:
        transcript = valid_transcript().replace(
            f"{RUNNER.PREFIX} milestone={RUNNER.MILESTONES[2]}",
            f"{RUNNER.PREFIX} milestone {RUNNER.MILESTONES[2]}",
        )
        with self.assertRaisesRegex(ValueError, "malformed"):
            RUNNER.validate_protocol(transcript)

    def test_protocol_rejects_exit_before_completion(self) -> None:
        lines = valid_transcript().splitlines()
        lines.pop(-2)
        with self.assertRaisesRegex(ValueError, "before milestone"):
            RUNNER.validate_protocol("\n".join(lines) + "\n")

    def test_protocol_rejects_record_after_exit(self) -> None:
        transcript = valid_transcript() + f"{RUNNER.PREFIX} milestone=userspace_entered\n"
        with self.assertRaisesRegex(ValueError, "after EXIT"):
            RUNNER.validate_protocol(transcript)

    def test_command_builds_limine_cdrom_run_with_qmp(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_64",
            image_kind="cdrom",
            image=pathlib.Path("kernel.iso"),
            boot_module=None,
        )
        command = RUNNER.build_command(
            arguments,
            pathlib.Path("serial.log"),
            pathlib.Path("qmp.sock"),
        )
        self.assertEqual("qemu-system-x86_64", command[0])
        self.assertIn("unix:qmp.sock,server=on,wait=off", command)
        self.assertEqual(["-boot", "d", "-cdrom", "kernel.iso"], command[-4:])

    def test_command_builds_multiboot_run_with_root_task(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_32",
            image_kind="kernel",
            image=pathlib.Path("kernel.elf"),
            boot_module=pathlib.Path("root_process.elf"),
        )
        command = RUNNER.build_command(
            arguments,
            pathlib.Path("serial.log"),
            pathlib.Path("qmp.sock"),
        )
        self.assertEqual("qemu-system-i386", command[0])
        self.assertEqual(
            ["-kernel", "kernel.elf", "-initrd", "root_process.elf"],
            command[-4:],
        )

    def test_command_rejects_boot_module_for_cdrom(self) -> None:
        arguments = types.SimpleNamespace(
            architecture="x86_32",
            image_kind="cdrom",
            image=pathlib.Path("kernel.iso"),
            boot_module=pathlib.Path("root_process.elf"),
        )
        with self.assertRaisesRegex(ValueError, "direct kernel"):
            RUNNER.build_command(
                arguments,
                pathlib.Path("serial.log"),
                pathlib.Path("qmp.sock"),
            )

    def test_last_completed_stage_reports_latest_valid_record(self) -> None:
        transcript = (
            f"{RUNNER.HEADER}\n"
            f"{RUNNER.PREFIX} milestone={RUNNER.MILESTONES[0]}\n"
            "unrelated diagnostic\n"
        )
        self.assertEqual(RUNNER.MILESTONES[0], RUNNER.last_completed_stage(transcript))

    def test_exit_detection_waits_for_a_complete_serial_line(self) -> None:
        self.assertFalse(RUNNER.has_complete_exit_record(f"{RUNNER.PREFIX} EXIT status="))
        self.assertFalse(RUNNER.has_complete_exit_record(f"{RUNNER.PREFIX} EXIT status=0"))
        self.assertTrue(RUNNER.has_complete_exit_record(f"{RUNNER.PREFIX} EXIT status=0\n"))


if __name__ == "__main__":
    unittest.main()