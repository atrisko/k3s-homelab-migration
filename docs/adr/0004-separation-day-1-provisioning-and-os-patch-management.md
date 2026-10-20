# ADR-0004: Separation between Day-1 Provisioning and OS Patch Management

* **Status:** Accepted
* **Date:** 2026-10-15

## Context

Initial provisioning of the K3s host is orchestrated via Ansible (`roles/os_base`), transforming a vanilla Debian installation into a hardened baseline host. 

Previously, `os_base` executed `upgrade: dist` during every playbook run. In practice, this created several operational risks:
1. **Non-deterministic Playbook Execution:** Routine configuration runs took varying amounts of time depending on pending upstream repository packages.
2. **Uncoordinated Daytime Updates:** Triggering an Ansible deployment to update a configuration file could inadvertently upgrade system libraries or runtimes in the middle of active workloads.
3. **Reboot Uncertainty:** Kernel or systemd updates could be applied during the day without an immediate reboot, leaving the system running on mismatched in-memory vs. on-disk binaries.

We need a clear architectural boundary between **Day-1 Provisioning** (establishing an idempotent baseline) and **Day-2 Lifecycle Maintenance** (security patching vs. major OS upgrades).

## Decision

We decouple operating system patch management from the Day-1 Ansible provisioning pipeline:

1. **Ansible Role Responsibility:** `roles/os_base` installs baseline utilities, enforces security hardening (SSH, sysctl, journald, module blacklisting), and configures the automated patching subsystem, but does not execute interactive full system upgrades (`upgrade: dist` was removed).
2. **Automated Security Patching via `unattended-upgrades`:**
   * Automated updates are strictly constrained to the Debian security stream (`label=Debian-Security`).
   * Execution is scheduled via native systemd timers (`apt-daily.timer`, `apt-daily-upgrade.timer`).
3. **Kernel Package Blacklisting:**
   * Kernel packages (`linux-image*`, `linux-headers*`) are explicitly excluded from automatic updates to prevent unexpected ABI breaks or driver issues.
4. **Scheduled Maintenance Reboot Window:**
   * Automatic reboots required by security patches are restricted to an off-peak maintenance window (default: `03:00`).
5. **Major Distribution & Kernel Upgrades:**
   * Upgrades outside the Debian Security stream and kernel upgrades remain manual administrative procedures executed deliberately after testing in staging environments (RemoteLab).

## Consequences

**Positive:**
* **Fast & Predictable Ansible Runs:** Playbook execution is deterministic and finishes in seconds; unchanged baselines report `changed=0`.
* **Autonomous Security Hygiene:** Zero-day vulnerabilities in common userspace libraries (e.g., OpenSSL, glibc, curl) are remediated automatically without administrator intervention.
* **Workload Stability:** No risk of daytime service interruptions or container restarts caused by ad-hoc package updates during Ansible deployments.
* **Driver Integrity:** Blacklisting kernel images ensures storage drivers (open-iscsi, nfs) and CNI network drivers do not break unattended.

**Negative & Trade-offs:**
* **Scheduled Reboot Downtime:** A single-node host reboot at 03:00 causes a brief interruption of running container workloads (acceptable for homelab single-node operations).
* **Manual Kernel Maintenance:** Administrators must periodically review, test, and apply kernel updates manually.
* **Environment Drift Potential:** If manual kernel/OS upgrades are not applied consistently across environments, staging and production may diverge over time.

## Alternatives Considered

* **`upgrade: dist` on Every Ansible Run (Former Implementation):**
  * *Rejected:* Violates separation of concerns. Makes CI/CD runs slow and non-deterministic, and risks unpredictable package changes during daytime deployments.
* **Fully Automated Upgrades (Including Kernel Packages):**
  * *Rejected:* Unattended kernel updates carry an unacceptable risk of boot failures or broken out-of-tree/network drivers without rollback mechanisms ready.
* **Kured (Kubernetes Reboot Daemon):**
  * *Deferred:* In multi-node clusters, hard uncoordinated 03:00 node reboots are an anti-pattern. Kured coordinates reboots by performing `kubectl cordon` and `kubectl drain` before rebooting nodes sequentially. This will be evaluated when transitioning from single-node to multi-node production.
