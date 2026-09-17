#!/usr/bin/env python3

import pathlib
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: rewrite_ir.py INPUT OUTPUT")

    source = pathlib.Path(sys.argv[1]).read_text()
    lines = source.splitlines(keepends=True)
    rewritten = 0

    for index, line in enumerate(lines):
        if not line.startswith("@__sancov_lowest_stack = "):
            continue
        if "thread_local(initialexec) " not in line:
            raise SystemExit("unexpected sanitizer stack declaration")
        lines[index] = line.replace("thread_local(initialexec) ", "", 1)
        rewritten += 1

    if rewritten != 1:
        raise SystemExit(f"expected one sanitizer stack declaration, found {rewritten}")

    pathlib.Path(sys.argv[2]).write_text("".join(lines))


if __name__ == "__main__":
    main()