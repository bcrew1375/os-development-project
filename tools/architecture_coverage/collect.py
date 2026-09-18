#!/usr/bin/env python3

import pathlib
import subprocess
import sys

import frame
import llvm_ir


POINTS_FORMAT = "OS_ARCHITECTURE_COVERAGE_POINTS"
POINTS_VERSION = 2


def validate_executable(executable_path: pathlib.Path, architecture: str) -> None:
    file_header = subprocess.run(
        ["readelf", "--file-header", str(executable_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    expected_header_values = {
        "x86_32": ("ELF32", "Intel 80386"),
        "x86_64": ("ELF64", "Advanced Micro Devices X86-64"),
    }[architecture]
    if any(value not in file_header.stdout for value in expected_header_values):
        raise ValueError(
            f"executable does not match guest architecture {architecture}"
        )


def write_points(
    output_path: pathlib.Path,
    architecture: str,
    instrumentation_point_count: int,
    source_points: list[tuple[str, int, bool]],
) -> None:
    lines = [
        f"{POINTS_FORMAT}\t{POINTS_VERSION}\n",
        f"architecture\t{architecture}\n",
        f"instrumentation_points\t{instrumentation_point_count}\n",
        f"source_points\t{len(source_points)}\n",
        "points\n",
    ]
    lines.extend(
        f"{source_path}\t{line}\t{int(covered)}\n"
        for source_path, line, covered in source_points
    )
    output_path.write_text("".join(lines))


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: collect.py IR ELF FRAME OUTPUT")
    llvm_ir_path, executable_path, frame_path, output_path = map(
        pathlib.Path,
        sys.argv[1:],
    )
    try:
        coverage_frame = frame.parse(frame_path.read_bytes())
        validate_executable(executable_path, coverage_frame.architecture)
        source_points, llvm_instrumentation_point_count = llvm_ir.coverage_points(
            llvm_ir_path.read_text(),
            coverage_frame.covered_points_bitmap,
        )
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
    if llvm_instrumentation_point_count != coverage_frame.instrumentation_point_count:
        raise SystemExit(
            "instrumentation mismatch: "
            f"guest={coverage_frame.instrumentation_point_count}, "
            f"llvm={llvm_instrumentation_point_count}"
        )
    write_points(
        output_path,
        coverage_frame.architecture,
        coverage_frame.instrumentation_point_count,
        source_points,
    )


if __name__ == "__main__":
    main()