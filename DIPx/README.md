# DIPx

DIPx is the VMware ESXi deployment track for DIP. Its bootstrap is designed for field use: prepare media once, boot a target from USB or PXE/iPXE, and let ESXi plus a disposable STOKER controller bring the automation plane online without requiring DCUI work.

## Bootstrap flow

1. Start with an unmodified ESXi 7/8 installer ISO from Broadcom or the hardware OEM.
2. Build the lean DIPx STOKER controller ISO from a Debian 13 netinst ISO.
3. Place that ISO on the VMFS6 datastore labeled `REPO` at the configured `CONTROLLER_ISO_RELATIVE` path.
4. Copy `ESXI/dipx.conf.example` to `ESXI/dipx.conf` and set deployment-specific values.
5. Generate a SHA-512 crypt hash for the ESXi root password with `openssl passwd -6` and put only the hash in the local config.
6. Review `INSTALL_TARGETS`, then explicitly set `CONFIRM_DISK_WIPE=YES`.
7. Build either a bootable ESXi ISO for USB/virtual media or an HTTP/iPXE tree. The builder generates a unique `dipx-controller` API credential unless one is supplied through the environment.
8. Boot the target. ESXi installs unattended, configures management networking, mounts `REPO`, creates the semantic port groups, creates the controller API account, and creates/powers on the STOKER controller VM.
9. STOKER installs unattended, reboots without a LUKS prompt, retrieves the ESXi credential through root-only VMware GuestInfo, stores it under `/etc/stoker/secrets`, removes the plaintext password from GuestInfo, stages `govc`, and marks itself controller-ready.

Once the machine has booted from the prepared USB/PXE source, the intended happy path requires no local monitor, keyboard, DCUI interaction, or IPMI console input.

## Shared configuration

`ESXI/dipx.conf` is shared by the ESXi and STOKER builders. The example defaults to:

```text
ESXi:       10.0.99.2
Controller: 10.0.99.11
Controller: stoker01.nerd.dipx
REPO ISO:   images/isos/stoker-dipx-amd64.iso
```

The config file is parsed as literal `KEY=VALUE` data and is never sourced as shell code.

## Build the STOKER controller

DIPx uses STOKER for the provisional controller instead of the old Oracle Linux kickstart. This keeps the controller small, purpose-built, offline-capable, and already shaped around Ansible orchestration.

The DIPx profile intentionally differs from a normal STOKER appliance:

- Ansible/controller tooling is enabled.
- Docker, routing, DHCP, and DNS appliance modules are disabled.
- `open-vm-tools` and `govc` are included.
- The controller has one management NIC.
- The controller uses a static management address from `dipx.conf`.
- Disk encryption is disabled so an unattended VM reboot cannot stop at a LUKS prompt.

Normal STOKER builds continue to default to LUKS. DIPx currently depends on the generic `encryption: none` and static-network support introduced by STOKER PR #3.

Example:

```bash
cd DIPx
cp ESXI/dipx.conf.example ESXI/dipx.conf

export STOKER_PASSWORD_HASH="$(openssl passwd -6)"
STOKER/build-controller.sh \
  --stoker-dir ~/src/STOKER \
  --source-iso ~/iso/debian-13-amd64-netinst.iso \
  --config ESXI/dipx.conf \
  --output ./stoker-dipx-amd64.iso
```

Copy the completed ISO to the `REPO` datastore at:

```text
/vmfs/volumes/REPO/images/isos/stoker-dipx-amd64.iso
```

## USB / ISO deployment

```bash
cd DIPx/ESXI
openssl passwd -6
$EDITOR dipx.conf

./build-esxi-iso.sh \
  --iso ~/iso/VMware-VMvisor-Installer-8.x.iso \
  --config ./dipx.conf \
  --output ./DIPx-ESXi-8.iso
```

The builder writes a SHA-256 sidecar and verifies that `/KS.CFG` plus both legacy and EFI boot configurations can be read back from the completed image.

The resulting ISO is suitable for USB writing or BMC virtual-media boot. Firmware/BMC boot order is the only expected precondition: once the target enters the customized installer, DIPx is intended to run unattended.

## PXE / iPXE deployment

The network-boot exporter starts from the exact same customized ISO, then converts it into an HTTP-served ESXi tree. This prevents the USB and PXE installation paths from developing separate kickstarts or configuration assumptions.

```bash
cd DIPx/ESXI

./build-esxi-netboot.sh \
  --iso ~/iso/VMware-VMvisor-Installer-8.x.iso \
  --config ./dipx.conf \
  --base-url http://10.0.99.5/dipx/esxi8 \
  --output-dir /srv/http/dipx/esxi8
```

Serve that directory at the configured URL and chain the generated:

```text
http://10.0.99.5/dipx/esxi8/boot.ipxe
```

The exporter patches the ESXi `prefix=` and kickstart URL for HTTP loading while preserving the vendor module ordering.

## Design decisions

### STOKER is disposable infrastructure, not another full server

The controller exists to get DIPx from "fresh ESXi" to a managed deployment plane. It therefore does not carry STOKER's full network-appliance module set and does not use LUKS. The security tradeoff is deliberate: the VMFS datastore and generated installer/controller media must be treated as deployment-sensitive, while rebooting the provisional controller remains fully unattended.

### Zero-touch ESXi credential handoff

The ESXi builder creates a unique high-entropy password for a local `dipx-controller` account on every build unless `DIPX_ESXI_API_PASSWORD` is explicitly supplied in the environment. `%firstboot` creates that account with the ESXi `Admin` role and injects the host, username, and password into the STOKER VM's VMware GuestInfo metadata.

The VMX explicitly requires authenticated GuestInfo `info-get`/`info-set`, so a normal guest user cannot read the pending password. A root systemd bootstrap service retrieves it through VMware Tools, writes `/etc/stoker/secrets/dipx-esxi.env` as `0640 root:stoker`, and immediately overwrites the GuestInfo password with `consumed`.

This removes the last planned console password handoff, but it means the generated ESXi ISO contains a unique plaintext bootstrap/API credential inside its rendered kickstart. Generated deployment media is therefore sensitive even though Git contains no reusable plaintext password. DIPx deliberately does **not** add `GOVC_INSECURE=1`; certificate trust/pinning should be handled explicitly when the controller starts performing API actions.

### Port-group names are semantic by default

Names such as `VLAN99-Mgmt` match the existing ESXi/DIP naming convention. They do **not** imply that the physical network is currently using VLAN 99. The default `PORTGROUPS` values use VLAN ID `0`, which is untagged.

Actual 802.1Q tagging is already configurable by changing the numeric ID for a port group, for example:

```text
PORTGROUPS=VLAN10-Users:10,VLAN20-Servers:20,VLAN99-Mgmt:99
```

This lets DIPx grow into real segmentation without forcing VLAN assumptions on a flat field network.

### USB storage belongs to ESXi while REPO is mounted

DIPx intentionally stops and disables `usbarbitrator` during first boot. That exposes USB mass storage to the ESXi host so the USB-backed VMFS6 datastore labeled `REPO` can remain mounted. The tradeoff is that those USB devices are not simultaneously available for guest USB passthrough.

### Disk selection favors zero-touch compatibility

`INSTALL_TARGETS` is an ordered selector list. The example is:

```text
localesx,DELL\ BOSS-N1,local
```

That prefers an existing ESXi system disk during rebuilds, explicitly handles the Dell BOSS-N1 case, and retains `local` as the broad fallback. For a homogeneous fleet, narrow or reorder this list to the known boot hardware before producing field media.

The install still uses `--overwritevmfs`, so `CONFIRM_DISK_WIPE=YES` remains a mandatory build-time acknowledgement. Zero-touch must not become zero-thought.

### SSH is opt-in

The local first-boot bootstrap does not require ESXi SSH. `ENABLE_SSH=0` remains the default.

### Preserve vendor boot structure

The ISO builder changes only `/KS.CFG` and the legacy/EFI boot configuration needed to point at it, then asks xorriso to replay the source image's boot equipment. The PXE exporter starts from that same generated image. Neither path regenerates or reorders the ESXi module list.

### Secure Boot is documented, not prioritized

The current design intentionally keeps ESXi `%firstboot` because it provides the shortest zero-touch bridge from installed ESXi to mounted `REPO` and a running STOKER controller. `%firstboot` does not execute with ESXi Secure Boot enabled.

DIPx therefore currently expects Secure Boot to be disabled for this bootstrap path. Moving the remaining first-boot work behind an API-driven controller is still a valid future hardening step, but it is not worth adding operator friction to the initial field deployment just to preserve Secure Boot today.

## Current automation boundary

At the end of this bootstrap, STOKER has:

- a deterministic management address,
- `open-vm-tools`,
- an embedded `govc`,
- an embedded DIPx Ansible project,
- a locally staged ESXi API credential,
- no requirement for ESXi SSH.

The next implementation layer should establish explicit ESXi TLS trust, validate the `govc` API session, then move VM/network/service deployment into the embedded STOKER project. That keeps the remaining `%firstboot` logic small and lets the controller take over immediately after it has a trustworthy API channel.
