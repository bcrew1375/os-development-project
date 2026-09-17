#!/usr/bin/env python3

import pathlib
import re
import struct
import sys


MAGIC = b"OSCV0001"
HEADER = struct.Struct("<8sHBBII")


def unescape(value: str) -> str:
    return re.sub(
        r"\\([0-9A-Fa-f]{2})",
        lambda match: chr(int(match.group(1), 16)),
        value.replace(r'\"', '"').replace(r"\\", "\\"),
    )


def parse_metadata(ir: str) -> dict[int, list[tuple[str, int]]]:
    nodes = {
        int(match.group(1)): match.group(2)
        for match in re.finditer(r"^!(\d+) = (.+)$", ir, re.MULTILINE)
    }
    files: dict[int, str] = {}
    for node_id, value in nodes.items():
        if "!DIFile(" not in value:
            continue
        filename = re.search(r'filename: "((?:[^"\\]|\\.)*)"', value)
        directory = re.search(r'directory: "((?:[^"\\]|\\.)*)"', value)
        if filename and directory:
            files[node_id] = str(
                pathlib.PurePosixPath(unescape(directory.group(1)))
                / unescape(filename.group(1))
            )

    locations: dict[int, tuple[int, int, int | None]] = {}
    for node_id, value in nodes.items():
        if "!DILocation(" not in value:
            continue
        line = re.search(r"line: (\d+)", value)
        scope = re.search(r"scope: !(\d+)", value)
        inlined_at = re.search(r"inlinedAt: !(\d+)", value)
        if line and scope:
            locations[node_id] = (
                int(line.group(1)),
                int(scope.group(1)),
                int(inlined_at.group(1)) if inlined_at else None,
            )

    def scope_file(scope_id: int) -> str | None:
        visited: set[int] = set()
        while scope_id not in visited:
            visited.add(scope_id)
            if scope_id in files:
                return files[scope_id]
            value = nodes.get(scope_id, "")
            file_match = re.search(r"file: !(\d+)", value)
            if file_match and int(file_match.group(1)) in files:
                return files[int(file_match.group(1))]
            parent = re.search(r"scope: !(\d+)", value)
            if not parent:
                return None
            scope_id = int(parent.group(1))
        return None

    resolved: dict[int, list[tuple[str, int]]] = {}
    for location_id in locations:
        frames: list[tuple[str, int]] = []
        current: int | None = location_id
        visited: set[int] = set()
        while current is not None and current not in visited and current in locations:
            visited.add(current)
            line, scope_id, inlined_at = locations[current]
            path = scope_file(scope_id)
            if path:
                frames.append((path, line))
            current = inlined_at
        resolved[location_id] = frames
    return resolved


def coverage_points(ir: str, seen: bytes) -> tuple[list[tuple[str, int, bool]], int]:
    locations = parse_metadata(ir)
    points: list[tuple[str, int, bool]] = []
    global_offsets: dict[str, int] = {}
    point_count = 0
    for match in re.finditer(
        r"^@(__sancov_gen_(?:\.\d+)?) = .*?global \[(\d+) x i32\].*?section \"__sancov_guards\"",
        ir,
        re.MULTILINE,
    ):
        global_offsets[match.group(1)] = point_count
        point_count += int(match.group(2))

    current_guard: int | None = None
    current_covered = False
    for line in ir.splitlines():
        if line.startswith("define "):
            current_guard = None
            current_covered = False

        if "call void @__sanitizer_cov_trace_pc_guard(" in line:
            name = re.search(r"@(__sancov_gen_(?:\.\d+)?)", line)
            element = re.search(r"i64 0, i64 (\d+)\)", line)
            if not name or name.group(1) not in global_offsets:
                raise ValueError("unable to identify sanitizer guard")
            current_guard = global_offsets[name.group(1)] + (
                int(element.group(1)) if element else 0
            )
            current_covered = (
                current_guard < len(seen) * 8
                and (seen[current_guard // 8] & (1 << (current_guard % 8))) != 0
            )

        if current_guard is None:
            continue
        debug_location = re.search(r"!dbg !(\d+)", line)
        if debug_location:
            for path, line_number in locations.get(int(debug_location.group(1)), []):
                points.append((path, line_number, current_covered))
    return points, point_count


def parse_frame(frame: bytes) -> tuple[int, bytes]:
    if len(frame) < HEADER.size:
        raise ValueError("coverage frame is truncated")
    magic, version, architecture, pointer_width, point_count, bitmap_byte_count = HEADER.unpack_from(frame)
    if magic != MAGIC or version != 1:
        raise ValueError("invalid coverage frame header")
    if architecture != 2 or pointer_width != 8:
        raise ValueError("coverage frame does not describe x86-64")
    expected_size = HEADER.size + bitmap_byte_count
    if len(frame) != expected_size:
        raise ValueError("coverage frame size does not match its header")
    if bitmap_byte_count != (point_count + 7) // 8:
        raise ValueError("coverage bitmap length does not match point count")
    return point_count, frame[HEADER.size:]


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: collect.py IR ELF FRAME OUTPUT")
    ir_path, _elf_path, frame_path, output_path = map(pathlib.Path, sys.argv[1:])
    try:
        point_count, seen = parse_frame(frame_path.read_bytes())
    except ValueError as error:
        raise SystemExit(str(error)) from error

    ir = ir_path.read_text()
    points, ir_point_count = coverage_points(ir, seen)
    if ir_point_count != point_count:
        raise SystemExit(
            f"instrumentation mismatch: guest={point_count}, ir={ir_point_count}"
        )
    pathlib.Path(output_path).write_text(
        "".join(f"{path}\t{line}\t{int(covered)}\n" for path, line, covered in points)
    )


if __name__ == "__main__":
    main()