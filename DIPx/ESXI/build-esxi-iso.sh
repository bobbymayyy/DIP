#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  build-esxi-iso.sh --iso SOURCE.iso --config dipx.conf [--output OUTPUT.iso] [--force]

Builds a bootable ESXi 7/8 installer ISO with a rendered DIPx kickstart embedded
as /KS.CFG. The original ISO boot layout is replayed by xorriso; only KS.CFG,
BOOT.CFG, and EFI/BOOT/BOOT.CFG are replaced.

Required config values are documented in dipx.conf.example.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf 'DIPx: %s\n' "$*"; }

SOURCE_ISO=""
CONFIG_FILE=""
OUTPUT_ISO=""
FORCE=0

while (($#)); do
  case "$1" in
    --iso) [[ $# -ge 2 ]] || die "--iso requires a path"; SOURCE_ISO=$2; shift 2 ;;
    --config) [[ $# -ge 2 ]] || die "--config requires a path"; CONFIG_FILE=$2; shift 2 ;;
    --output) [[ $# -ge 2 ]] || die "--output requires a path"; OUTPUT_ISO=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_ISO" ]] || die "--iso is required"
[[ -n "$CONFIG_FILE" ]] || die "--config is required"
[[ -r "$SOURCE_ISO" ]] || die "cannot read source ISO: $SOURCE_ISO"
[[ -r "$CONFIG_FILE" ]] || die "cannot read config: $CONFIG_FILE"
command -v xorriso >/dev/null 2>&1 || die "xorriso is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

# Parse a deliberately small KEY=VALUE format without sourcing executable shell.
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
  key=${key%$'\r'}
  value=${value%$'\r'}
  [[ -z "$key" || "$key" == \#* ]] && continue
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid config key: $key"
  printf -v "$key" '%s' "$value"
done < "$CONFIG_FILE"

required=(
  ESXI_VERSION ESXI_ROOTPW_HASH ESXI_IP ESXI_NETMASK ESXI_GATEWAY ESXI_DNS
  ESXI_HOSTNAME INSTALL_TARGET CONFIRM_DISK_WIPE NTP_SERVER REPO_LABEL
  DATASTORE_LABEL PROV_VM_NAME MGMT_PORTGROUP PROV_ISO_RELATIVE PORTGROUPS
  ENABLE_SSH DEBUG
)
for key in "${required[@]}"; do
  [[ -n "${!key:-}" ]] || die "missing config value: $key"
done

[[ "$ESXI_VERSION" == "7" || "$ESXI_VERSION" == "8" ]] || die "ESXI_VERSION must be 7 or 8"
[[ "$ESXI_ROOTPW_HASH" == '$6$'* ]] || die "ESXI_ROOTPW_HASH must be a SHA-512 crypt hash beginning with \$6\$"
[[ "$CONFIRM_DISK_WIPE" == "YES" ]] || die "refusing to build destructive installer: set CONFIRM_DISK_WIPE=YES after verifying INSTALL_TARGET"
[[ "$ENABLE_SSH" == "0" || "$ENABLE_SSH" == "1" ]] || die "ENABLE_SSH must be 0 or 1"
[[ "$DEBUG" == "0" || "$DEBUG" == "1" ]] || die "DEBUG must be 0 or 1"
[[ "$PORTGROUPS" == *"${MGMT_PORTGROUP}:"* ]] || die "MGMT_PORTGROUP must also appear in PORTGROUPS"
[[ "$PROV_ISO_RELATIVE" != /* && "$PROV_ISO_RELATIVE" != *".."* ]] || die "PROV_ISO_RELATIVE must be a safe relative path"

TEMPLATE="${SCRIPT_DIR}/ks${ESXI_VERSION}.cfg"
[[ -r "$TEMPLATE" ]] || die "missing kickstart template: $TEMPLATE"

if [[ -z "$OUTPUT_ISO" ]]; then
  OUTPUT_ISO="${PWD}/DIPx-ESXi-${ESXI_VERSION}.iso"
fi
if [[ -e "$OUTPUT_ISO" && "$FORCE" -ne 1 ]]; then
  die "output already exists: $OUTPUT_ISO (use --force to replace)"
fi
mkdir -p "$(dirname -- "$OUTPUT_ISO")"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/dipx-esxi.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

rendered_ks="$WORKDIR/KS.CFG"
legacy_cfg="$WORKDIR/BOOT.CFG"
efi_cfg="$WORKDIR/EFI_BOOT.CFG"

export ESXI_ROOTPW_HASH ESXI_IP ESXI_NETMASK ESXI_GATEWAY ESXI_DNS ESXI_HOSTNAME
export INSTALL_TARGET NTP_SERVER REPO_LABEL DATASTORE_LABEL PROV_VM_NAME
export MGMT_PORTGROUP PROV_ISO_RELATIVE PORTGROUPS ENABLE_SSH DEBUG

python3 - "$TEMPLATE" "$rendered_ks" <<'PY'
import os
import re
import sys
from pathlib import Path

src, dst = map(Path, sys.argv[1:3])
text = src.read_text(encoding="utf-8")
keys = set(re.findall(r"@@([A-Z][A-Z0-9_]*)@@", text))
missing = sorted(k for k in keys if not os.environ.get(k))
if missing:
    raise SystemExit("missing template values: " + ", ".join(missing))
for key in keys:
    text = text.replace(f"@@{key}@@", os.environ[key])
if re.search(r"@@[A-Z][A-Z0-9_]*@@", text):
    raise SystemExit("unresolved template token remains")
dst.write_text(text, encoding="utf-8", newline="\n")
PY

boot_cfg_paths=$(xorriso -indev "$SOURCE_ISO" -find / -type f -iname boot.cfg -print 2>/dev/null || true)
LEGACY_BOOT_PATH=$(printf '%s\n' "$boot_cfg_paths" | awk 'NF && $0 ~ "^\/[^\/]+$" {print; exit}')
EFI_BOOT_PATH=$(printf '%s\n' "$boot_cfg_paths" | awk 'tolower($0) == "/efi/boot/boot.cfg" {print; exit}')
[[ -n "$LEGACY_BOOT_PATH" ]] || die "source ISO has no root boot.cfg"
[[ -n "$EFI_BOOT_PATH" ]] || die "source ISO has no EFI/BOOT/boot.cfg"

xorriso -osirrox on -indev "$SOURCE_ISO" -extract "$LEGACY_BOOT_PATH" "$legacy_cfg" >/dev/null 2>&1 || die "failed to extract $LEGACY_BOOT_PATH"
xorriso -osirrox on -indev "$SOURCE_ISO" -extract "$EFI_BOOT_PATH" "$efi_cfg" >/dev/null 2>&1 || die "failed to extract $EFI_BOOT_PATH"

patch_boot_cfg() {
  local cfg=$1
  python3 - "$cfg" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
lines = p.read_text(encoding="utf-8", errors="strict").splitlines()
out = []
seen = False
for line in lines:
    if line.startswith("kernelopt="):
        seen = True
        value = line[len("kernelopt="):].strip()
        parts = [x for x in value.split() if not x.startswith("ks=")]
        if "runweasel" not in parts:
            parts.insert(0, "runweasel")
        parts.append("ks=cdrom:/KS.CFG")
        line = "kernelopt=" + " ".join(parts)
    out.append(line)
if not seen:
    raise SystemExit(f"{p}: no kernelopt= line found")
p.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
PY
}

patch_boot_cfg "$legacy_cfg"
patch_boot_cfg "$efi_cfg"

rm -f -- "$OUTPUT_ISO"
log "source ISO: $SOURCE_ISO"
log "target disk selector: $INSTALL_TARGET"
log "building ESXi $ESXI_VERSION installer: $OUTPUT_ISO"

# Modify the vendor ISO in xorriso native mode and replay its existing BIOS/UEFI
# boot equipment. This avoids reconstructing or reordering the ESXi module list.
xorriso \
  -indev "$SOURCE_ISO" \
  -outdev "$OUTPUT_ISO" \
  -overwrite on \
  -map "$rendered_ks" /KS.CFG \
  -map "$legacy_cfg" "$LEGACY_BOOT_PATH" \
  -map "$efi_cfg" "$EFI_BOOT_PATH" \
  -boot_image any replay \
  -commit \
  -end >/dev/null

[[ -s "$OUTPUT_ISO" ]] || die "xorriso did not produce an output ISO"

# Verify the three intended mutations can be read back from the result.
verify_dir="$WORKDIR/verify"
mkdir -p "$verify_dir"
xorriso -osirrox on -indev "$OUTPUT_ISO" -extract /KS.CFG "$verify_dir/KS.CFG" >/dev/null 2>&1 || die "output ISO missing /KS.CFG"
xorriso -osirrox on -indev "$OUTPUT_ISO" -extract "$LEGACY_BOOT_PATH" "$verify_dir/BOOT.CFG" >/dev/null 2>&1 || die "output ISO missing $LEGACY_BOOT_PATH"
xorriso -osirrox on -indev "$OUTPUT_ISO" -extract "$EFI_BOOT_PATH" "$verify_dir/EFI_BOOT.CFG" >/dev/null 2>&1 || die "output ISO missing $EFI_BOOT_PATH"
grep -Fq 'ks=cdrom:/KS.CFG' "$verify_dir/BOOT.CFG" || die "legacy boot config does not reference kickstart"
grep -Fq 'ks=cdrom:/KS.CFG' "$verify_dir/EFI_BOOT.CFG" || die "EFI boot config does not reference kickstart"
cmp -s "$rendered_ks" "$verify_dir/KS.CFG" || die "embedded kickstart does not match rendered kickstart"

sha256sum "$OUTPUT_ISO" > "${OUTPUT_ISO}.sha256"
log "verified embedded kickstart and both boot paths"
log "SHA-256 written to ${OUTPUT_ISO}.sha256"
