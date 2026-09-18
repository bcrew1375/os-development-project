#!/usr/bin/env python3

import pathlib
import re


def _unescape(value: str) -> str:
    return re.sub(
        r"\\([0-9A-Fa-f]{2})",
        lambda match: chr(int(match.group(1), 16)),
        value.replace(r'\"', '"').replace(r"\\", "\\"),
    )


def _parse_metadata(llvm_ir_text: str) -> dict[int, list[tuple[str, int]]]:
    metadata_nodes = {
        int(match.group(1)): match.group(2)
        for match in re.finditer(r"^!(\d+) = (.+)$", llvm_ir_text, re.MULTILINE)
    }
    source_files: dict[int, str] = {}
    for node_id, metadata_value in metadata_nodes.items():
        if "!DIFile(" not in metadata_value:
            continue
        filename = re.search(r'filename: "((?:[^"\\]|\\.)*)"', metadata_value)
        directory = re.search(r'directory: "((?:[^"\\]|\\.)*)"', metadata_value)
        if filename and directory:
            source_files[node_id] = str(
                pathlib.PurePosixPath(_unescape(directory.group(1)))
                / _unescape(filename.group(1))
            )

    locations: dict[int, tuple[int, int, int | None]] = {}
    for node_id, metadata_value in metadata_nodes.items():
        if "!DILocation(" not in metadata_value:
            continue
        line = re.search(r"line: (\d+)", metadata_value)
        scope = re.search(r"scope: !(\d+)", metadata_value)
        inlined_at = re.search(r"inlinedAt: !(\d+)", metadata_value)
        if line and scope:
            locations[node_id] = (
                int(line.group(1)),
                int(scope.group(1)),
                int(inlined_at.group(1)) if inlined_at else None,
            )

    def source_file_for_scope(scope_id: int) -> str | None:
        visited_scope_ids: set[int] = set()
        while scope_id not in visited_scope_ids:
            visited_scope_ids.add(scope_id)
            if scope_id in source_files:
                return source_files[scope_id]
            metadata_value = metadata_nodes.get(scope_id, "")
            file_match = re.search(r"file: !(\d+)", metadata_value)
            if file_match and int(file_match.group(1)) in source_files:
                return source_files[int(file_match.group(1))]
            parent = re.search(r"scope: !(\d+)", metadata_value)
            if not parent:
                return None
            scope_id = int(parent.group(1))
        return None

    source_locations: dict[int, list[tuple[str, int]]] = {}
    for location_id in locations:
        frames: list[tuple[str, int]] = []
        current: int | None = location_id
        visited_location_ids: set[int] = set()
        while (
            current is not None
            and current not in visited_location_ids
            and current in locations
        ):
            visited_location_ids.add(current)
            line, scope_id, inlined_at = locations[current]
            source_path = source_file_for_scope(scope_id)
            if source_path:
                frames.append((source_path, line))
            current = inlined_at
        source_locations[location_id] = frames
    return source_locations


def coverage_points(
    llvm_ir_text: str,
    covered_points_bitmap: bytes,
) -> tuple[list[tuple[str, int, bool]], int]:
    source_locations = _parse_metadata(llvm_ir_text)
    source_points: list[tuple[str, int, bool]] = []
    guard_array_offsets: dict[str, int] = {}
    instrumentation_point_count = 0
    for match in re.finditer(
        r'^@(__sancov_gen_(?:\.\d+)?) = .*?global \[(\d+) x i32\].*?section "__sancov_guards"',
        llvm_ir_text,
        re.MULTILINE,
    ):
        guard_array_name = match.group(1)
        if guard_array_name in guard_array_offsets:
            raise ValueError(f"duplicate sanitizer guard array: {guard_array_name}")
        guard_array_offsets[guard_array_name] = instrumentation_point_count
        instrumentation_point_count += int(match.group(2))
    if not guard_array_offsets:
        raise ValueError("LLVM IR contains no sanitizer guard arrays")

    current_guard_index: int | None = None
    current_block_was_covered = False
    for llvm_ir_line in llvm_ir_text.splitlines():
        if llvm_ir_line.startswith("define "):
            current_guard_index = None
            current_block_was_covered = False
        if "call void @__sanitizer_cov_trace_pc_guard(" in llvm_ir_line:
            guard_array = re.search(r"@(__sancov_gen_(?:\.\d+)?)", llvm_ir_line)
            guard_element = re.search(
                r"i(?:32|64) 0, i(?:32|64) (\d+)\)",
                llvm_ir_line,
            )
            if not guard_array or guard_array.group(1) not in guard_array_offsets:
                raise ValueError(
                    "unsupported sanitizer guard reference: "
                    f"{llvm_ir_line.strip()}"
                )
            current_guard_index = guard_array_offsets[guard_array.group(1)] + (
                int(guard_element.group(1)) if guard_element else 0
            )
            if current_guard_index >= instrumentation_point_count:
                raise ValueError(
                    f"sanitizer guard index is out of range: {current_guard_index}"
                )
            current_block_was_covered = bitmap_contains(
                covered_points_bitmap,
                current_guard_index,
            )
        if current_guard_index is None:
            continue
        debug_location = re.search(r"!dbg !(\d+)", llvm_ir_line)
        if debug_location:
            location_id = int(debug_location.group(1))
            for source_path, line_number in source_locations.get(location_id, []):
                source_points.append(
                    (source_path, line_number, current_block_was_covered)
                )
    return source_points, instrumentation_point_count


def bitmap_contains(bitmap: bytes, index: int) -> bool:
    return index < len(bitmap) * 8 and (bitmap[index // 8] & (1 << (index % 8))) != 0