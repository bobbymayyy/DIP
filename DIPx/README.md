# DIPx

DIPx is the VMware ESXi deployment track for DIP. This directory currently implements the bootstrap chain from a vendor ESXi installer ISO to a local provisioning VM that can continue the enclave build from the offline `REPO` datastore.

## Bootstrap flow

1. Start with an unmodified ESXi 7 or ESXi 8 installer ISO from Broadcom/OEM media.
2. Copy `ESXI/dipx.conf.example` to `ESXI/dipx.conf` and set host-specific values.
3. Generate a SHA-512 crypt hash for the ESXi root password with `openssl passwd -6` and place only the resulting hash in the local config.
4. Verify `INSTALL_TARGET`, then explicitly set `CONFIRM_DISK_WIPE=YES`.
5. Run `ESXI/build-esxi-iso.sh`. The builder renders the version-specific kickstart as `/KS.CFG`, changes only the `kernelopt=` line in the legacy and EFI boot configs, and asks xorriso to replay the vendor ISO's existing boot equipment.
6. Boot the generated ISO. ESXi installs unattended, configures the management network, mounts the offline datastore labeled `REPO`, creates the configured VLAN port groups, and creates/powers on `prov01` from the provisioning ISO on `REPO`.
7. `prov01` becomes the control point for the rest of DIPx automation.

Example:

```bash
cd DIPx/ESXI
cp dipx.conf.example dipx.conf
openssl passwd -6
$EDITOR dipx.conf
./build-esxi-iso.sh \
  --iso ~/iso/VMware-VMvisor-Installer-8.x.iso \
  --config ./dipx.conf \
  --output ./DIPx-ESXi-8.iso
```

The builder also writes `DIPx-ESXi-8.iso.sha256` and verifies that `/KS.CFG` plus both boot configuration paths can be read back from the completed ISO.

## Safety and security decisions

### No deployment password in Git

The old kickstarts contained a reusable ESXi root password. The kickstarts are now templates and require `ESXI_ROOTPW_HASH` at build time. `dipx.conf` and generated ISOs are ignored by Git because the ISO itself contains the password hash and deployment-specific network details.

### Destructive disk selection is explicit

The ESXi install line uses `--overwritevmfs`. `INSTALL_TARGET=local` remains available for portable field deployments, but the builder will not produce an ISO until `CONFIRM_DISK_WIPE=YES` is deliberately set. On hosts with multiple local disks, prefer a hardware-specific `--firstdisk` selector instead of `local`.

### SSH is opt-in

The bootstrap does not require remote SSH. `ENABLE_SSH=0` is the default, so the host is not left with SSH enabled merely for convenience. Set it to `1` only when the deployment workflow actually needs it.

### Preserve vendor boot structure

The builder does not regenerate the ESXi module list. It replaces only `/KS.CFG` and the two boot config files, changing only `kernelopt=` to add `ks=cdrom:/KS.CFG`. xorriso then replays the source ISO's boot equipment. This minimizes drift from vendor/OEM media and avoids reordering ESXi boot modules.

### Secure Boot is an unresolved architectural boundary

The current bootstrap deliberately retains ESXi `%firstboot` because it is what mounts `REPO` and creates the provisioning VM without needing another machine. Broadcom documents that `%firstboot` does not run when Secure Boot is enabled. DIPx does **not** automatically disable Secure Boot or hide that tradeoff.

For this implementation, Secure Boot must be disabled for the `%firstboot` bootstrap path to complete. The preferred next-stage architecture is to move post-install host configuration and provisioner creation to an external/API-driven bootstrap path so Secure Boot can remain enabled.

## Configuration reference

`ESXI/dipx.conf.example` is the source of truth for build-time settings. Key knobs include:

- ESXi version, hostname, management IP, DNS, gateway, and NTP
- hashed root password
- destructive install target selector
- `REPO` and primary datastore labels
- provisioner VM name and ISO location
- management port group and VLAN list
- SSH and debug toggles

The config parser treats values as literal text and does not source the file as shell code.

## Current handoff

The provisioning ISO is expected at:

```text
/vmfs/volumes/REPO/<PROV_ISO_RELATIVE>
```

The example uses:

```text
images/isos/OL10-prov.iso
```

The existing provisioning kickstart under `REPO/install/ks/prov.cfg` and Ansible skeleton under `REPO/ansible/` are the next implementation layer after the ESXi bootstrap is reliable.
