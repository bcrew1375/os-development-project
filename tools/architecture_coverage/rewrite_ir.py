#!/usr/bin/env python3

import pathlib
import sys


def rewrite(source: str, architecture: str) -> str:
    if architecture not in {"x86_32", "x86_64"}:
        raise ValueError(f"unsupported architecture: {architecture}")
    lines = source.splitlines(keepends=True)
    declarations = [
        index
        for index, line in enumerate(lines)
        if "__sancov_lowest_stack" in line
        and "thread_local(initialexec)" in line
    ]
    if len(declarations) != 1:
        raise ValueError(
            f"expected one sanitizer stack declaration, found {len(declarations)}"
        )
    declaration_index = declarations[0]
    declaration = lines[declaration_index]
    declaration_name = declaration.split(" = ", 1)[0]
    replacement_name = "@runtime.__sancov_lowest_stack"
    has_runtime_definition = any(
        line.startswith(replacement_name + " = ") for line in lines
    )
    if has_runtime_definition:
        lines[declaration_index] = ""
        for index, line in enumerate(lines):
            if line.startswith(declaration_name + " = alias "):
                lines[index] = ""
            else:
                lines[index] = line.replace(declaration_name, replacement_name)
    else:
        lines[declaration_index] = declaration.replace(
            "thread_local(initialexec) ",
            "",
            1,
        )

    if architecture == "x86_32":
        stack_definition = next(
            (line for line in lines if line.startswith(replacement_name + " = ")),
            lines[declaration_index],
        )
        if 'section ".multiboot.data"' not in stack_definition:
            raise ValueError(
                "x86-32 sanitizer stack state is not in low bootstrap data"
            )
        callbacks = [
            line
            for line in lines
            if line.startswith("define ")
            and (
                "@__sanitizer_cov_trace_pc_guard(" in line
                or "@runtime.traceProgramCounter(" in line
            )
        ]
        if len(callbacks) != 1:
            raise ValueError(
                f"expected one sanitizer callback, found {len(callbacks)}"
            )
        if 'section ".multiboot.text"' not in callbacks[0]:
            raise ValueError("x86-32 sanitizer callback is not in low bootstrap text")
    return "".join(lines)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: rewrite_ir.py INPUT ARCHITECTURE OUTPUT")

    try:
        result = rewrite(pathlib.Path(sys.argv[1]).read_text(), sys.argv[2])
    except ValueError as error:
        raise SystemExit(str(error)) from error
    pathlib.Path(sys.argv[3]).write_text(result)


if __name__ == "__main__":
    main()