#!/usr/bin/env python3

import importlib.util
import io
import os
import pathlib
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_watcher():
    path = ROOT / "tools/zlint_watch.py"
    spec = importlib.util.spec_from_file_location("zlint_watch", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


WATCHER = load_watcher()
SIGNATURE = WATCHER.FileSignature(modified_nanoseconds=1, size_bytes=10)


class ZlintWatchTests(unittest.TestCase):
    def test_snapshot_keeps_watched_files_and_skips_cache_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            root = pathlib.Path(directory_name)
            (root / "src").mkdir()
            (root / "src/kernel.zig").write_text("pub fn main() void {}\n")
            (root / "zlint.json").write_text("{}\n")
            (root / "README.md").write_text("documentation\n")
            (root / ".zig-cache").mkdir()
            (root / ".zig-cache/generated.zig").write_text("pub const cached = 1;\n")
            (root / "zig-out").mkdir()
            (root / "zig-out/artifact.zig").write_text("pub const artifact = 1;\n")

            snapshot = WATCHER.take_snapshot(root)

        self.assertEqual(["src/kernel.zig", "zlint.json"], sorted(snapshot))

    def test_select_changed_paths_reports_additions_removals_and_edits(self) -> None:
        edited = WATCHER.FileSignature(modified_nanoseconds=2, size_bytes=10)
        previous = {"kept.zig": SIGNATURE, "edited.zig": SIGNATURE, "removed.zig": SIGNATURE}
        current = {"kept.zig": SIGNATURE, "edited.zig": edited, "added.zig": SIGNATURE}

        self.assertEqual(
            ["added.zig", "edited.zig", "removed.zig"],
            WATCHER.select_changed_paths(previous, current),
        )

    def test_select_changed_paths_is_empty_for_identical_snapshots(self) -> None:
        self.assertEqual(
            [],
            WATCHER.select_changed_paths({"kernel.zig": SIGNATURE}, {"kernel.zig": SIGNATURE}),
        )

    def test_snapshot_detects_an_edited_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            root = pathlib.Path(directory_name)
            source = root / "kernel.zig"
            source.write_text("const value: u32 = 1;\n")
            previous = WATCHER.take_snapshot(root)
            source.write_text("const value: u32 = 2;\n")
            os.utime(source, ns=(2_000_000_000, 2_000_000_000))
            current = WATCHER.take_snapshot(root)

        self.assertEqual(["kernel.zig"], WATCHER.select_changed_paths(previous, current))

    def test_format_lint_pass_brackets_findings_with_markers(self) -> None:
        rendered = WATCHER.format_lint_pass(
            "::warning file=src/kernel.zig,line=1,col=1,title=no-print::message\n",
            description="pass 1: 0 changed, 1 findings, 0.001s",
        )

        self.assertEqual(
            [
                "zlint-watch: pass 1: 0 changed, 1 findings, 0.001s",
                WATCHER.BEGIN_MARKER,
                "::warning file=src/kernel.zig,line=1,col=1,title=no-print::message",
                WATCHER.END_MARKER,
            ],
            rendered.splitlines(),
        )

    def test_format_lint_pass_still_ends_a_pass_without_findings(self) -> None:
        rendered = WATCHER.format_lint_pass(
            "",
            description="pass 2: 1 changed, 0 findings, 0.001s",
        )

        self.assertEqual(
            [
                "zlint-watch: pass 2: 1 changed, 0 findings, 0.001s",
                WATCHER.BEGIN_MARKER,
                WATCHER.END_MARKER,
            ],
            rendered.splitlines(),
        )

    def test_run_watch_once_lints_through_the_injected_runner(self) -> None:
        with tempfile.TemporaryDirectory() as directory_name:
            root = pathlib.Path(directory_name)
            (root / "src").mkdir()
            (root / "src/kernel.zig").write_text("pub fn main() void {}\n")
            calls: list[WATCHER.WatchSettings] = []

            def fake_lint(settings: WATCHER.WatchSettings) -> str:
                calls.append(settings)
                return "::warning file=src/kernel.zig,line=1,col=1,title=no-print::message\n"

            output = io.StringIO()
            settings = WATCHER.WatchSettings(root=root, config_path=root / "zlint.json")
            exit_status = WATCHER.run_watch(
                settings,
                once=True,
                lint_runner=fake_lint,
                output=output,
            )

        self.assertEqual(0, exit_status)
        self.assertEqual([settings], calls)
        rendered_lines = output.getvalue().splitlines()
        self.assertIn(WATCHER.BEGIN_MARKER, rendered_lines)
        self.assertIn(WATCHER.END_MARKER, rendered_lines)

    def test_parse_arguments_defaults_to_a_single_pass_only_when_requested(self) -> None:
        parsed = WATCHER.parse_arguments(["--root", "/tmp", "--once"])

        self.assertTrue(parsed.once)
        self.assertEqual(pathlib.Path("/tmp"), parsed.root)
        self.assertEqual(WATCHER.DEFAULT_EXECUTABLE, parsed.executable)


if __name__ == "__main__":
    unittest.main()
