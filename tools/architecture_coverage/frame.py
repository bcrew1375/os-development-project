#!/usr/bin/env python3

from dataclasses import dataclass
import struct


MAGIC = b"OSCV0001"
VERSION = 1
HEADER = struct.Struct("<8sHBBII")
ARCHITECTURES = {
    1: ("x86_32", 4),
    2: ("x86_64", 8),
}


@dataclass(frozen=True)
class Frame:
    architecture: str
    instrumentation_point_count: int
    covered_points_bitmap: bytes


def parse(frame_bytes: bytes) -> Frame:
    if len(frame_bytes) < HEADER.size:
        raise ValueError("coverage frame is truncated")
    magic, version, architecture_id, pointer_width, point_count, bitmap_size = (
        HEADER.unpack_from(frame_bytes)
    )
    if magic != MAGIC:
        raise ValueError("coverage frame has invalid magic")
    if version != VERSION:
        raise ValueError(f"unsupported coverage frame version: {version}")
    architecture = ARCHITECTURES.get(architecture_id)
    if architecture is None:
        raise ValueError(f"unsupported coverage architecture: {architecture_id}")
    architecture_name, expected_pointer_width = architecture
    if pointer_width != expected_pointer_width:
        raise ValueError("coverage frame architecture and pointer width do not match")
    if bitmap_size != (point_count + 7) // 8:
        raise ValueError("coverage bitmap length does not match point count")
    if len(frame_bytes) != HEADER.size + bitmap_size:
        raise ValueError("coverage frame size does not match its header")
    return Frame(
        architecture=architecture_name,
        instrumentation_point_count=point_count,
        covered_points_bitmap=frame_bytes[HEADER.size :],
    )