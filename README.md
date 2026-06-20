# DIP: Deployable Infrastructure Platform

**DIP** is a deployable infrastructure platform built to rapidly stand up incident response and defensive cyber operations infrastructure. The project is split into two platform tracks:

- **DIP**: Proxmox VE-based deployment path
- **DIPx**: VMware ESXi-based deployment path

The goal is to make repeatable infrastructure deployment faster, more consistent, and more useful during time-sensitive response scenarios where teams need networking, collaboration, storage, issue tracking, and security monitoring stood up quickly.

## What This Project Does

DIP automates the deployment of a small response-ready infrastructure stack using shell orchestration and Ansible playbooks. It is designed around the idea that an incident response environment should be reproducible, portable, and quick to rebuild.

At a high level, DIP can help deploy:

- Proxmox VE cluster configuration
- OPNsense routing and virtual switching
- Nextcloud for local file sharing and storage
- Mattermost for team communication
- Redmine for project and issue tracking
- Security Onion for network/security monitoring and analysis

The project also includes configuration files for supporting services such as PXE/iPXE booting, DNS/DHCP, nginx, package repositories, and terminal workflow helpers.

## Repository Layout

```text
DIP/
├── DIP/                  # Proxmox VE deployment track
│   ├── ansible/           # Ansible configuration, inventory, and playbooks
│   │   ├── ansible.cfg
│   │   ├── inventory.cfg
│   │   └── playbooks/
│   ├── configs/           # Supporting configs for boot, DNS/DHCP, nginx, repos, tmux, etc.
│   ├── docs/              # Architecture and contingency diagrams
│   └── RUN_ME.sh          # Main interactive deployment script
│
└── DIPx/                 # VMware ESXi deployment track
    ├── ESXI/
    └── REPO/
```

## Platform Tracks

### DIP: Proxmox VE

The Proxmox VE path is the most developed deployment track in the repository. It uses an interactive shell script to prepare the environment, configure SSH access, discover Proxmox nodes, build or reference a cluster, generate Ansible inventory, and call deployment or teardown playbooks.

The deployment flow is centered around `DIP/RUN_ME.sh` and the playbooks under `DIP/ansible/playbooks/`.

### DIPx: VMware ESXi

DIPx appears to be the VMware ESXi-oriented branch of the same concept. It is organized separately under `DIPx/` with ESXi and repository-related directories.

## Deployment Components

### Infrastructure Automation

DIP uses Ansible playbooks to perform deployment and teardown actions. The Proxmox playbook set includes deployment playbooks for core services and matching teardown playbooks for cleanup.

Examples include:

```text
01_configure_proxmox.yml
11_deploy_opnsense.yml
21_deploy_nextcloud.yml
22_deploy_mattermost.yml
23_deploy_redmine.yml
33_deploy_securityonion.yml
911_destroy_opnsense.yml
921_destroy_nextcloud.yml
922_destroy_mattermost.yml
923_destroy_redmine.yml
931_destroy_securityonion.yml
932_destroy_securityonion.yml
933_destroy_securityonion.yml
```

### Interactive Control Script

`RUN_ME.sh` acts as the main operator entry point. It provides a dialog-based menu for choosing infrastructure actions, viewing vault-protected values, and running deployment or teardown workflows.

The script performs tasks such as:

- Checking for required tools like `dialog` and Ansible
- Installing dependencies from local packages or online package managers
- Detecting whether the script is running on a Proxmox host
- Discovering Proxmox nodes on the expected management subnet
- Configuring passwordless SSH between control and target nodes
- Creating or joining a Proxmox cluster
- Generating the Ansible inventory file
- Running selected Ansible deployment or destruction playbooks

## Intended Use Case

DIP is best understood as a fast-build cyber range or response enclave toolkit. It is not just a homelab installer. The design points toward a practical field scenario: a team needs to rapidly deploy infrastructure for analysis, coordination, evidence handling, monitoring, or recovery support.

Potential use cases include:

- Incident response infrastructure staging
- Defensive cyber operations support environments
- Malware or risky analysis support networks
- Temporary collaboration and case-management infrastructure
- Training ranges and lab environments
- Rebuildable infrastructure for continuity exercises

## Requirements

The exact requirements will depend on the deployment path and target environment, but the Proxmox track expects some combination of:

- Proxmox VE nodes
- Linux control node or direct execution from a Proxmox node
- Root access to target Proxmox hosts
- Bash
- Ansible
- `dialog`
- `sshpass`
- Open vSwitch utilities
- `python3-proxmoxer`
- Network access between control node and Proxmox nodes
- Local `.deb` or `.rpm` package bundles when operating without internet access

## Basic Usage

Clone the repository:

```bash
git clone https://github.com/bobbymayyy/DIP.git
cd DIP/DIP
```

Run the interactive deployment script:

```bash
chmod +x RUN_ME.sh
sudo ./RUN_ME.sh
```

From there, use the menu to choose infrastructure deployment or teardown actions.

> Note: Review and customize inventories, playbooks, IP ranges, vault values, and configuration files before running this against real infrastructure.

## Security Notes

This project touches sensitive infrastructure functions, including hypervisor configuration, routing, SSH trust, Ansible Vault data, and incident response tooling. Before production use, review the following carefully:

- Hardcoded IP ranges and assumptions
- Root SSH behavior
- Password handling
- Ansible Vault contents
- Generated inventory files
- Playbook destructive actions
- Teardown workflows
- Network bridge and ingestion interface selection
- Any local package bundles included for offline operation

## Project Status

This repository represents an early but substantial infrastructure automation project. The codebase shows a strong focus on practical deployment speed, operator workflow, offline/limited-connectivity operation, and repeatable cyber infrastructure builds.

Some areas that may benefit from future cleanup:

- Add a root-level `README.md`
- Separate configuration variables from shell logic
- Replace hardcoded network ranges with documented variables
- Add example inventories and sanitized vault templates
- Add diagrams directly to the README
- Add screenshots of the deployment menus
- Document expected topology and network assumptions
- Add tested deployment scenarios
- Add clearer DIP vs. DIPx usage guidance

## Why It Matters

DIP is a rebuildable infrastructure forge for incident response. Instead of manually standing up tools one by one during a high-pressure event, the platform aims to turn the process into a repeatable deployment workflow.

That makes the project valuable not only as code, but as a demonstration of systems architecture, automation, cybersecurity operations, virtualization, networking, and business continuity thinking.
