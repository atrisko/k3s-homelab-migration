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
3. **Kernel Security Patches Included (Review 2 R2-8):**
   * Kernel packages (`linux-image*`, `linux-headers*`) from `Debian-Security` are permitted and no longer blacklisted.
   * *Rationale:* ZFS and out-of-tree DKMS modules were explicitly rejected to prevent excessive SSD wear-and-tear on consumer storage (Tier-2 storage decision: ADR-0009). All required drivers (ext4, nvme, virtio, open-iscsi, nfs) are in-tree and maintained within Debian stable point-releases. Container escape CVEs in the Linux kernel are remediated automatically rather than lingering unpatched.
4. **Scheduled Maintenance Reboot Window:**
   * Automatic reboots required by security patches (including new kernel installations) are restricted to an off-peak maintenance window (default: `03:00`).
5. **Major Distribution Upgrades:**
   * Full distribution upgrades (`dist-upgrade` / major Debian releases) remain manual administrative procedures executed deliberately after testing in staging environments (RemoteLab).

## Consequences

**Positive:**
* **Fast & Predictable Ansible Runs:** Playbook execution is deterministic and finishes in seconds; unchanged baselines report `changed=0`.
* **Timely Remediation of Kernel & Userspace CVEs:** Both critical container-escape kernel vulnerabilities and userspace libraries (OpenSSL, glibc, curl) are patched automatically via Debian-Security.
* **Driver Integrity Preserved:** In-tree drivers (storage, networking) remain stable across point-release security updates without DKMS build risks.
* **Workload Stability:** No risk of daytime service interruptions or container restarts caused by ad-hoc package updates during Ansible deployments.

**Negative & Trade-offs:**
* **Scheduled Reboot Downtime:** A single-node host reboot at 03:00 causes a brief interruption of running container workloads (acceptable for homelab single-node operations).
* **Multi-Node Transition Need:** Hard uncoordinated reboots at 03:00 must be replaced by Kured (Kubernetes Reboot Daemon) once transitioning to a multi-node cluster.

## Alternatives Considered

* **`upgrade: dist` on Every Ansible Run (Former Implementation):**
  * *Rejected:* Violates separation of concerns. Makes CI/CD runs slow and non-deterministic, and risks unpredictable package changes during daytime deployments.
* **Blacklisting Kernel Packages (Former Implementation, Review 2 R2-8):**
  * *Superseded:* Blacklisting the kernel while accepting 03:00 reboots left the system vulnerable to container escape CVEs while still incurring reboot downtime. Without ZFS/DKMS, there is no technical driver integrity risk.
* **Kured (Kubernetes Reboot Daemon):**
  * *Deferred:* In multi-node clusters, hard uncoordinated 03:00 node reboots are an anti-pattern. Kured coordinates reboots by performing `kubectl cordon` and `kubectl drain` before rebooting nodes sequentially. This will be evaluated when transitioning from single-node to multi-node production.
