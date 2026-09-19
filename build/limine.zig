const std = @import("std");

pub const BootModule = struct {
    source: std.Build.LazyPath,
    iso_name: []const u8,
};

pub fn createIso(
    b: *std.Build,
    kernel: std.Build.LazyPath,
    config: std.Build.LazyPath,
    boot_modules: []const BootModule,
    output_name: []const u8,
) std.Build.LazyPath {
    const script =
        \\set -eu
        \\kernel="$1"
        \\limine_conf="$2"
        \\output_iso="$3"
        \\iso_root="$(mktemp -d "$output_iso.root.XXXXXX")"
        \\temporary_iso="$output_iso.tmp.$$"
        \\limine_dir="/opt/limine"
        \\cleanup() {
        \\    rm -rf "$iso_root" "$temporary_iso"
        \\}
        \\trap cleanup EXIT
        \\
        \\require_tool() {
        \\    if ! command -v "$1" >/dev/null 2>&1; then
        \\        echo "missing required tool: $1" >&2
        \\        echo "rebuild the devcontainer so Limine ISO tooling is installed" >&2
        \\        exit 1
        \\    fi
        \\}
        \\
        \\find_limine_file() {
        \\    found="$(find "$limine_dir" -name "$1" -type f -print -quit 2>/dev/null || true)"
        \\    if [ -z "$found" ]; then
        \\        echo "missing Limine file: $1 under $limine_dir" >&2
        \\        exit 1
        \\    fi
        \\    printf '%s\n' "$found"
        \\}
        \\
        \\require_tool xorriso
        \\require_tool limine
        \\limine_bios_sys="$(find_limine_file limine-bios.sys)"
        \\limine_bios_cd="$(find_limine_file limine-bios-cd.bin)"
        \\
        \\mkdir -p "$iso_root/boot"
        \\cp "$kernel" "$iso_root/boot/kernel.elf"
        \\cp "$limine_conf" "$iso_root/boot/limine.conf"
        \\shift 3
        \\while [ "$#" -gt 0 ]; do
        \\    module_source="$1"
        \\    module_name="$2"
        \\    shift 2
        \\    case "$module_name" in
        \\        ""|*/*) echo "invalid Limine boot module name: $module_name" >&2; exit 1 ;;
        \\    esac
        \\    cp "$module_source" "$iso_root/boot/$module_name"
        \\done
        \\cp "$limine_bios_sys" "$iso_root/boot/limine-bios.sys"
        \\cp "$limine_bios_cd" "$iso_root/boot/limine-bios-cd.bin"
        \\
        \\xorriso -as mkisofs \
        \\    -b boot/limine-bios-cd.bin \
        \\    -no-emul-boot \
        \\    -boot-load-size 4 \
        \\    -boot-info-table \
        \\    "$iso_root" \
        \\    -o "$temporary_iso"
        \\limine bios-install "$temporary_iso"
        \\mv "$temporary_iso" "$output_iso"
    ;

    const command = b.addSystemCommand(&.{ "bash", "-c", script, "make-limine-iso" });
    command.has_side_effects = true;
    command.addFileArg(kernel);
    command.addFileArg(config);
    const output = command.addOutputFileArg(output_name);
    for (boot_modules) |module| {
        command.addFileArg(module.source);
        command.addArg(module.iso_name);
    }
    return output;
}
