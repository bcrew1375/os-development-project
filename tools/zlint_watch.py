#!/usr/bin/env python3

"""Re-run ZLint after every change to a watched file.

The VS Code task "Lint Zig (watch)" runs this script as a long-lived background
task. Each lint pass is bracketed by begin and end marker lines so the task's
background problem matcher replaces the findings reported by the previous pass.
That replacement is what lets an already-fixed finding disappear from the
Problems panel without manually re-running the linter.

ZLint analyzes the whole repository in milliseconds, so every pass lints all
watched files instead of only the paths that changed. Linting everything keeps
cross-file rules such as unused-decls accurate.

Errors are not recovered from silently: a missing ZLint binary stops the watch
loop with a non-zero exit status instead of reporting an empty, misleading pass.
"""

import argparse
import dataclasses
import os
import pathlib
import subprocess
import sys
import time
from typing import Callable, Mapping, Sequence, TextIO


BEGIN_MARKER = "zlint-watch: begin"
END_MARKER = "zlint-watch: end"
WATCHED_FILE_SUFFIXES = (".zig",)
WATCHED_FILE_NAMES = ("zlint.json",)
IGNORED_DIRECTORY_NAMES = frozenset({".git", ".zig-cache", "zig-out"})
CONFIG_FILE_NAME = "zlint.json"
DEFAULT_EXECUTABLE = "zlint"
DEFAULT_POLL_INTERVAL_SECONDS = 0.4
DEFAULT_SETTLE_DELAY_SECONDS = 0.25
DEFAULT_SETTLE_TIMEOUT_SECONDS = 5.0


@dataclasses.dataclass(frozen=True)
class FileSignature:
    """Identity of a watched file at the time it was last scanned."""

    modified_nanoseconds: int
    size_bytes: int


@dataclasses.dataclass(frozen=True)
class WatchSettings:
    """Everything the watch loop needs to detect changes and run ZLint."""

    root: pathlib.Path
    config_path: pathlib.Path | None
    executable: str = DEFAULT_EXECUTABLE
    poll_interval_seconds: float = DEFAULT_POLL_INTERVAL_SECONDS
    settle_delay_seconds: float = DEFAULT_SETTLE_DELAY_SECONDS
    settle_timeout_seconds: float = DEFAULT_SETTLE_TIMEOUT_SECONDS


def is_watched_file(path: pathlib.Path) -> bool:
    return path.suffix in WATCHED_FILE_SUFFIXES or path.name in WATCHED_FILE_NAMES


def take_snapshot(root: pathlib.Path) -> dict[str, FileSignature]:
    """Map every watched file below root to its modification signature."""
    snapshot: dict[str, FileSignature] = {}
    for directory, subdirectory_names, file_names in os.walk(root):
        subdirectory_names[:] = [
            name for name in subdirectory_names if name not in IGNORED_DIRECTORY_NAMES
        ]
        for file_name in file_names:
            path = pathlib.Path(directory, file_name)
            if not is_watched_file(path):
                continue
            try:
                status = path.stat()
            except OSError:
                continue
            snapshot[str(path.relative_to(root))] = FileSignature(
                modified_nanoseconds=status.st_mtime_ns,
                size_bytes=status.st_size,
            )
    return snapshot


def select_changed_paths(
    previous: Mapping[str, FileSignature],
    current: Mapping[str, FileSignature],
) -> list[str]:
    """Return the watched paths added, removed, or modified since previous."""
    return sorted(
        name for name in previous.keys() | current.keys() if previous.get(name) != current.get(name)
    )


def run_zlint(settings: WatchSettings) -> str:
    """Run one full ZLint pass and return its GitHub-formatted diagnostics."""
    command = [settings.executable]
    if settings.config_path is not None:
        command += ["--config", str(settings.config_path)]
    command += ["--format", "github", "."]
    completed = subprocess.run(
        command,
        cwd=settings.root,
        capture_output=True,
        text=True,
        errors="replace",
        check=False,
    )
    if completed.stderr:
        sys.stderr.write(completed.stderr)
    return completed.stdout


def count_findings(lint_output: str) -> int:
    return sum(1 for line in lint_output.splitlines() if line.startswith("::"))


def describe_pass(
    pass_number: int,
    changed_path_count: int,
    finding_count: int,
    elapsed_seconds: float,
) -> str:
    return (
        f"pass {pass_number}: {changed_path_count} changed, "
        f"{finding_count} findings, {elapsed_seconds:.3f}s"
    )


def format_lint_pass(lint_output: str, description: str) -> str:
    """Render one pass as a human header plus the problem matcher markers."""
    lines = [f"zlint-watch: {description}", BEGIN_MARKER]
    body = lint_output.rstrip("\n")
    if body:
        lines.append(body)
    lines.append(END_MARKER)
    return "\n".join(lines) + "\n"


def wait_until_settled(
    settings: WatchSettings,
    current: Mapping[str, FileSignature],
) -> dict[str, FileSignature]:
    """Wait out an editor's multi-file save burst before linting again."""
    deadline = time.monotonic() + settings.settle_timeout_seconds
    snapshot = dict(current)
    while time.monotonic() < deadline:
        time.sleep(settings.settle_delay_seconds)
        updated = take_snapshot(settings.root)
        if updated == snapshot:
            return updated
        snapshot = updated
    return snapshot


def wait_for_change(
    settings: WatchSettings,
    previous: Mapping[str, FileSignature],
) -> tuple[dict[str, FileSignature], list[str]]:
    """Block until a watched file changes, then return a settled snapshot."""
    while True:
        time.sleep(settings.poll_interval_seconds)
        current = take_snapshot(settings.root)
        if select_changed_paths(previous, current):
            settled = wait_until_settled(settings, current)
            return settled, select_changed_paths(previous, settled)


def run_watch(
    settings: WatchSettings,
    *,
    once: bool = False,
    lint_runner: Callable[[WatchSettings], str] = run_zlint,
    output: TextIO = sys.stdout,
) -> int:
    """Lint immediately, then relint after every change until interrupted."""
    snapshot = take_snapshot(settings.root)
    changed_paths: list[str] = []
    pass_number = 0
    while True:
        pass_number += 1
        started = time.monotonic()
        lint_output = lint_runner(settings)
        elapsed_seconds = time.monotonic() - started
        description = describe_pass(
            pass_number,
            len(changed_paths),
            count_findings(lint_output),
            elapsed_seconds,
        )
        output.write(format_lint_pass(lint_output, description))
        output.flush()
        if once:
            return 0
        snapshot, changed_paths = wait_for_change(settings, snapshot)


def default_config_path(root: pathlib.Path) -> pathlib.Path | None:
    candidate = root / CONFIG_FILE_NAME
    return candidate if candidate.is_file() else None


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Re-run ZLint after every change to a watched file.",
    )
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path.cwd(),
        help="Directory to watch and lint (default: current directory)",
    )
    parser.add_argument(
        "--config",
        type=pathlib.Path,
        help=f"ZLint configuration file (default: <root>/{CONFIG_FILE_NAME} when present)",
    )
    parser.add_argument(
        "--executable",
        default=DEFAULT_EXECUTABLE,
        help=f"ZLint binary to run (default: {DEFAULT_EXECUTABLE})",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL_SECONDS,
        help="Seconds between change scans",
    )
    parser.add_argument(
        "--settle-delay",
        type=float,
        default=DEFAULT_SETTLE_DELAY_SECONDS,
        help="Seconds to wait for further changes before linting again",
    )
    parser.add_argument(
        "--settle-timeout",
        type=float,
        default=DEFAULT_SETTLE_TIMEOUT_SECONDS,
        help="Longest number of seconds to wait for changes to settle",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single lint pass and exit",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    parsed = parse_arguments(arguments)
    root = parsed.root.resolve()
    settings = WatchSettings(
        root=root,
        config_path=parsed.config.resolve() if parsed.config else default_config_path(root),
        executable=parsed.executable,
        poll_interval_seconds=parsed.poll_interval,
        settle_delay_seconds=parsed.settle_delay,
        settle_timeout_seconds=parsed.settle_timeout,
    )
    try:
        return run_watch(settings, once=parsed.once)
    except KeyboardInterrupt:
        return 0
    except FileNotFoundError:
        sys.stderr.write(f"zlint-watch: '{settings.executable}' was not found on PATH\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
