#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  build-controller.sh --stoker-dir PATH --source-iso debian-13-netinst.iso \
    --config ../ESXI/dipx.conf [--output stoker-dipx-amd64.iso] [--force]

Builds the lean STOKER appliance used as the provisional DIPx controller.
The STOKER checkout must include support for encryption:none and static installer
networking (STOKER PR #3 until that capability is merged to latest).

Required environment:
  STOKER_PASSWORD_HASH   crypt(3) password hash for the local stoker account
USAGE
}

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf 'DIPx/STOKER: %s\n' "$*"; }

STOKER_DIR=""
SOURCE_ISO=""
CONFIG_FILE=""
OUTPUT=""
FORCE=0

while (($#)); do
  case "$1" in
    --stoker-dir) [[ $# -ge 2 ]] || die "--stoker-dir requires a path"; STOKER_DIR=$2; shift 2 ;;
    --source-iso) [[ $# -ge 2 ]] || die "--source-iso requires a path"; SOURCE_ISO=$2; shift 2 ;;
    --config) [[ $# -ge 2 ]] || die "--config requires a path"; CONFIG_FILE=$2; shift 2 ;;
    --output) [[ $# -ge 2 ]] || die "--output requires a path"; OUTPUT=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$STOKER_DIR" && -d "$STOKER_DIR" ]] || die "--stoker-dir must point to a STOKER checkout"
[[ -x "$STOKER_DIR/build.sh" ]] || die "STOKER build.sh not found or not executable: $STOKER_DIR/build.sh"
[[ -n "$SOURCE_ISO" && -r "$SOURCE_ISO" ]] || die "--source-iso must be readable"
[[ -n "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "--config must be readable"
[[ -n "${STOKER_PASSWORD_HASH:-}" ]] || die "export STOKER_PASSWORD_HASH before building the controller"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

if ! grep -q '"none"' "$STOKER_DIR/schemas/stoker-build.schema.json" 2>/dev/null || \
   ! grep -q '"static"' "$STOKER_DIR/schemas/stoker-build.schema.json" 2>/dev/null; then
  die "STOKER checkout lacks the unattended controller profile capabilities; use STOKER PR #3 or newer"
fi

# Read the shared DIPx KEY=VALUE config as data, never as shell code.
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
  key=${key%$'\r'}
  value=${value%$'\r'}
  [[ -z "$key" || "$key" == \#* ]] && continue
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid config key: $key"
  printf -v "$key" '%s' "$value"
done < "$CONFIG_FILE"

required=(CONTROLLER_HOSTNAME CONTROLLER_IP CONTROLLER_NETMASK CONTROLLER_GATEWAY CONTROLLER_DNS)
for key in "${required[@]}"; do
  [[ -n "${!key:-}" ]] || die "missing config value: $key"
done
for key in CONTROLLER_IP CONTROLLER_NETMASK CONTROLLER_GATEWAY; do
  [[ "${!key}" =~ ^[0-9.]+$ ]] || die "$key contains unsupported characters"
done
[[ "$CONTROLLER_DNS" =~ ^[A-Za-z0-9._:-]+$ ]] || die "CONTROLLER_DNS contains unsupported characters"
[[ "$CONTROLLER_HOSTNAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "CONTROLLER_HOSTNAME contains unsupported characters"

SOURCE_ISO="$(cd -- "$(dirname -- "$SOURCE_ISO")" && pwd)/$(basename -- "$SOURCE_ISO")"
STOKER_DIR="$(cd -- "$STOKER_DIR" && pwd)"
CONFIG_FILE="$(cd -- "$(dirname -- "$CONFIG_FILE")" && pwd)/$(basename -- "$CONFIG_FILE")"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${PWD}/stoker-dipx-amd64.iso"
fi
if [[ -e "$OUTPUT" && "$FORCE" -ne 1 ]]; then
  die "output already exists: $OUTPUT (use --force to replace)"
fi
mkdir -p "$(dirname -- "$OUTPUT")"
OUTPUT="$(cd -- "$(dirname -- "$OUTPUT")" && pwd)/$(basename -- "$OUTPUT")"

SHORT_HOST=${CONTROLLER_HOSTNAME%%.*}
if [[ "$CONTROLLER_HOSTNAME" == *.* ]]; then
  DOMAIN=${CONTROLLER_HOSTNAME#*.}
else
  DOMAIN=dipx.internal
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/dipx-stoker.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/overlay" "$WORKDIR/output" "$WORKDIR/work" "$WORKDIR/logs"

# Retain STOKER's normal runtime/inventory overlay and layer DIPx autostart on top.
if [[ -d "$STOKER_DIR/overlays/rootfs" ]]; then
  cp -a "$STOKER_DIR/overlays/rootfs/." "$WORKDIR/overlay/"
fi
cp -a "$SCRIPT_DIR/rootfs/." "$WORKDIR/overlay/"

q(){ python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
PROFILE="$WORKDIR/stoker-build.yaml"
cat > "$PROFILE" <<EOF
project:
  name: STOKER-DIPx
  version: "0.1.0"
  architecture: amd64

source_iso:
  path: $(q "$SOURCE_ISO")
  expected_sha256: null

output:
  directory: $(q "$WORKDIR/output")
  filename: stoker-dipx-amd64.iso
  volume_id: STOKER_DIPX

paths:
  work_directory: $(q "$WORKDIR/work")
  log_directory: $(q "$WORKDIR/logs")
  preseed_template: $(q "$STOKER_DIR/templates/preseed.cfg.j2")
  scripts_directory: $(q "$STOKER_DIR/scripts")
  iso_overlay: null
  rootfs_overlay: $(q "$WORKDIR/overlay")
  repositories: $(q "$STOKER_DIR/config/repositories.yaml")
  packages: $(q "$SCRIPT_DIR/profile/packages.yaml")
  modules: $(q "$SCRIPT_DIR/profile/modules.yaml")
  ansible_projects: $(q "$SCRIPT_DIR/profile/ansible-projects.yaml")

installer:
  locale: en_US.UTF-8
  keyboard: us
  timezone: America/New_York
  hostname: $(q "$SHORT_HOST")
  domain: $(q "$DOMAIN")
  account:
    username: stoker
    full_name: DIPx STOKER Controller
    password_hash_env: STOKER_PASSWORD_HASH
    disable_root: true
    groups: [sudo, users, netdev]
  disk:
    wipe_all_fixed_disks: false
    encryption: none
    lvm: true
    recipe: atomic
    guided_size: max
    volume_group: stoker-vg
    luks_passphrase_env: STOKER_LUKS_PASSPHRASE
    require_uefi: true
    erase_before_encryption: false
  installer_packages: [openssh-server, sudo, ca-certificates]

network:
  method: static
  interface: auto
  ip_address: $(q "$CONTROLLER_IP")
  netmask: $(q "$CONTROLLER_NETMASK")
  gateway: $(q "$CONTROLLER_GATEWAY")
  nameservers: [$(q "$CONTROLLER_DNS")]

repository:
  suite: stoker
  component: main
  trusted: true
  sign: false
  signing_key: null

boot:
  unattended_default: true
  timeout_seconds: 3
  kernel_arguments:
    - auto=true
    - priority=critical
    - preseed/file=/cdrom/stoker/preseed.cfg

build:
  include_recommends: false
  verify_downloads: true
  regenerate_md5: true
  preserve_original_boot_layout: true
  redact_logs: true
  qemu_smoke_test: false
EOF

# STOKER's current secret resolver still expects the LUKS environment variable
# even when encryption:none. The value below is never rendered into the DIPx ISO.
export STOKER_LUKS_PASSPHRASE=${STOKER_LUKS_PASSPHRASE:-DIPX_UNUSED_UNENCRYPTED_PROFILE}

log "building lean controller ${CONTROLLER_HOSTNAME} at ${CONTROLLER_IP}"
(
  cd "$STOKER_DIR"
  ./build.sh -c "$PROFILE" all
)

BUILT="$WORKDIR/output/stoker-dipx-amd64.iso"
[[ -s "$BUILT" ]] || die "STOKER did not produce $BUILT"
rm -f -- "$OUTPUT" "${OUTPUT}.sha256"
cp "$BUILT" "$OUTPUT"
sha256sum "$OUTPUT" > "${OUTPUT}.sha256"
log "built $OUTPUT"
log "place it on REPO at ${CONTROLLER_ISO_RELATIVE:-images/isos/stoker-dipx-amd64.iso}"
