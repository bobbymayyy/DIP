#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  build-esxi-netboot.sh --iso SOURCE.iso --config dipx.conf \
    --base-url http://pxe.example/esxi --output-dir ./netboot [--force]

Creates an HTTP/iPXE-ready ESXi tree from the same rendered installer used for
USB/ISO deployment. Serve OUTPUT_DIR at BASE_URL, then chain boot.ipxe.
USAGE
}

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf 'DIPx/iPXE: %s\n' "$*"; }

SOURCE_ISO=""
CONFIG_FILE=""
BASE_URL=""
OUTPUT_DIR=""
FORCE=0

while (($#)); do
  case "$1" in
    --iso) [[ $# -ge 2 ]] || die "--iso requires a path"; SOURCE_ISO=$2; shift 2 ;;
    --config) [[ $# -ge 2 ]] || die "--config requires a path"; CONFIG_FILE=$2; shift 2 ;;
    --base-url) [[ $# -ge 2 ]] || die "--base-url requires a URL"; BASE_URL=$2; shift 2 ;;
    --output-dir) [[ $# -ge 2 ]] || die "--output-dir requires a path"; OUTPUT_DIR=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -r "$SOURCE_ISO" ]] || die "source ISO is not readable: $SOURCE_ISO"
[[ -r "$CONFIG_FILE" ]] || die "config is not readable: $CONFIG_FILE"
[[ "$BASE_URL" =~ ^https?://[^[:space:]]+$ ]] || die "--base-url must be an http:// or https:// URL"
[[ -n "$OUTPUT_DIR" ]] || die "--output-dir is required"
command -v xorriso >/dev/null 2>&1 || die "xorriso is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

BASE_URL=${BASE_URL%/}
if [[ -e "$OUTPUT_DIR" ]]; then
  [[ "$FORCE" -eq 1 ]] || die "output directory exists: $OUTPUT_DIR (use --force to replace)"
  rm -rf -- "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/dipx-netboot.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
CUSTOM_ISO="$WORKDIR/dipx-esxi.iso"

"$SCRIPT_DIR/build-esxi-iso.sh" \
  --iso "$SOURCE_ISO" \
  --config "$CONFIG_FILE" \
  --output "$CUSTOM_ISO"

log "extracting customized installer tree"
xorriso -osirrox on -indev "$CUSTOM_ISO" -extract / "$OUTPUT_DIR" >/dev/null 2>&1

find_path() {
  local candidate
  for candidate in "$@"; do
    [[ -f "$OUTPUT_DIR/$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

LEGACY_CFG=$(find_path BOOT.CFG boot.cfg) || die "extracted tree has no root boot.cfg"
EFI_CFG=$(find_path EFI/BOOT/BOOT.CFG efi/boot/boot.cfg EFI/BOOT/boot.cfg efi/boot/BOOT.CFG) || die "extracted tree has no EFI boot.cfg"
EFI_LOADER=$(find_path EFI/BOOT/BOOTX64.EFI efi/boot/bootx64.efi EFI/BOOT/bootx64.efi efi/boot/BOOTX64.EFI) || die "extracted tree has no EFI bootx64.efi"

patch_cfg() {
  local cfg=$1
  python3 - "$OUTPUT_DIR/$cfg" "$BASE_URL" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
base = sys.argv[2].rstrip("/")
lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
out = []
seen_prefix = False
seen_kernelopt = False
for line in lines:
    if line.startswith("prefix="):
        line = f"prefix={base}"
        seen_prefix = True
    elif line.startswith("kernelopt="):
        value = line[len("kernelopt="):].strip()
        parts = [part for part in value.split() if not part.startswith("ks=")]
        if "runweasel" not in parts:
            parts.insert(0, "runweasel")
        parts.append(f"ks={base}/KS.CFG")
        line = "kernelopt=" + " ".join(parts)
        seen_kernelopt = True
    out.append(line)
if not seen_prefix:
    insert_at = next((i for i, line in enumerate(out) if line.startswith("kernel=")), 0)
    out.insert(insert_at, f"prefix={base}")
if not seen_kernelopt:
    raise SystemExit(f"{path}: no kernelopt= line found")
path.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
PY
}

patch_cfg "$LEGACY_CFG"
patch_cfg "$EFI_CFG"

cat > "$OUTPUT_DIR/boot.ipxe" <<EOF
#!ipxe
set base ${BASE_URL}
kernel \${base}/${EFI_LOADER} -c \${base}/${EFI_CFG}
boot
EOF

# Catch the most common web-root mismatch before the files leave the build host.
grep -Fq "prefix=${BASE_URL}" "$OUTPUT_DIR/$EFI_CFG" || die "EFI boot.cfg prefix verification failed"
grep -Fq "ks=${BASE_URL}/KS.CFG" "$OUTPUT_DIR/$EFI_CFG" || die "EFI kickstart URL verification failed"
[[ -s "$OUTPUT_DIR/KS.CFG" ]] || die "KS.CFG missing from netboot tree"

log "ready: serve $OUTPUT_DIR at $BASE_URL"
log "UEFI iPXE entry: ${BASE_URL}/boot.ipxe"
