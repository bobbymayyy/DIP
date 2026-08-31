# DIPx controller project

Embedded into the lean STOKER controller ISO. First boot stages `govc`, verifies VMware Tools, requires the one-time ESXi GuestInfo credential handoff, and marks the controller ready for later DIPx host/VM orchestration.

The ESXi installer creates a per-build `dipx-controller` Admin account and injects its host/user/password into the controller VM through VMware GuestInfo. The root-only bootstrap service copies that credential into `/etc/stoker/secrets/dipx-esxi.env` (`0640 root:stoker`) and immediately replaces the GuestInfo password with `consumed` before dropping privileges to run this Ansible project.

The secret file intentionally does not set `GOVC_INSECURE`. Establishing an explicit ESXi TLS trust/pinning policy is the next API-orchestration step; the zero-touch credential transport should not silently disable certificate verification.
