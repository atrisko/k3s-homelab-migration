# ADR-0002: RemoteLab Ansible Control Node (Dedicated VM vs. WSL 2)

* **Status:** Accepted
* **Date:** 2026-10-14

## Context

In the RemoteLab (Phase 4.5 staging environment on a managed Windows 11 host), an
Ansible control node is needed to orchestrate the target K3s VM over SSH.

Initially, using WSL 2 on the Windows host was planned as the control environment.
However, WSL is disabled on this corporate VDI session, and enabling it via DISM
requires a Windows reboot. Rebooting the host is not permitted in this environment
because it would terminate or reset the remote session.

## Decision

Deploy a dedicated, lightweight Debian 13 virtual machine (`ansible`,
1 vCPU, 1 GB RAM) on Hyper-V's external virtual switch to serve as the Ansible
control node instead of enabling WSL 2.

## Consequences

**Positive**

* **No host reboots or privileges needed:** Bypasses Windows GPO and reboot
  restrictions entirely.
* **Production-like architecture:** Mimics a dedicated management node or CI/CD
  runner operating over a real network boundary (SSH across L2/L3).
* **Isolation:** Full root access and clean Linux environment without WSL
  interoperability quirks (e.g. file permissions on mounted `/mnt/c/`).

**Negative / trade-offs**

* Consumes ~1 GB of the host's 16 GB RAM.
* Requires managing a second VM instance (OS installation, updates, SSH keys).

## Alternatives considered

* **WSL 2 on Windows 11 host:** Rejected because feature activation requires a
  host reboot that cannot be performed in the current VDI session.
* **Running Ansible locally on the K3s node (`localhost`):** Rejected because it
  does not validate remote SSH connectivity, inventory switching, and key-based
  authentication required for the eventual bare-metal rollout.
