# ADR-0008: Bulk Storage Architecture via mergerfs and SnapRAID on Bare Metal

* **Status:** Proposed
* **Date:** 2026-10-20

## Context

Our homelab infrastructure is undergoing migration from a legacy **Unraid server** to a declarative, single-node **Bare-Metal Debian 13 (Trixie)** system hosting a **K3s Kubernetes cluster**.

The system implements a strictly tiered storage model:
1. **Tier 1 (System):** Dedicated NVMe/SSD for Debian 13 base OS, system logs, and container runtime components.
2. **Tier 2 (Appdata / K3s PVCs):** Latency-sensitive NVMe/SSD mirror (handled by `local-path-provisioner`) hosting transactional workloads, databases (SQLite, PostgreSQL), and Kubernetes state.
3. **Tier 3 (Bulk Storage Pool):** Multi-terabyte capacity for media streaming, cold archives, document vaults, and backup repositories (predominantly WORM – *Write Once, Read Many* data).

Selecting the underlying storage architecture for **Tier 3 (Bulk Storage)** is constrained by several real-world requirements:

1. **In-Place Migration (Zero Copy / Zero Reformat):**  
   The existing Unraid data disks (~6.5+ TB across 4 TB drives, formatted with standard **XFS**) already contain production data. The migration must preserve existing partitions and filesystems in-place, eliminating the need to procure temporary multi-terabyte staging storage or perform high-risk bulk data copies across external networks.
2. **Heterogeneous Drive Scalability:**  
   While initial disks are homogeneous (4 TB each), future storage expansion will be incremental with mismatched drive capacities (e.g., 14 TB, 18 TB, or 22 TB). The storage pool must accept drives of arbitrary sizes without locking unused capacity to the smallest drive.
3. **Fault Isolation and Blast Radius:**  
   Catastrophic multi-drive failures exceeding parity tolerance must never corrupt the entire storage pool. Surviving disks must remain standard, independent Linux filesystems that can be read on any standard Linux machine.
4. **I/O Localization and Acoustic/Mechanical Profile:**  
   In an "always spun up" homelab environment (avoiding mechanical spin-up latency and spindle start/stop wear), reading single files (e.g., a media stream or document retrieval) should localize I/O to the physical disk hosting that specific file, avoiding synchronized multi-disk head thrashing across the entire pool.
5. **Declarative Ansible & GitOps Compatibility:**  
   The entire storage layer must be configurable via standard Linux packages, `/etc/fstab`, and systemd timers managed declaratively by Ansible without proprietary hypervisors or custom operating system overlays.

## Decision

We adopt a decoupled storage architecture combining **`mergerfs`** (union filesystem) and **`SnapRAID`** (snapshot parity) for the Bare-Metal Tier 3 bulk storage pool:

1. **Native Per-Disk Mounts:**  
   Data disks are mounted directly as individual native filesystems (e.g., `/mnt/disk1`, `/mnt/disk2`, ...) using persistent `/dev/disk/by-id/...` device paths in `/etc/fstab`. If LUKS encryption is used, disks are mapped via `/etc/crypttab` prior to mounting.
2. **Unified Namespace via `mergerfs`:**  
   All individual data disks are unified into a single logical mount point (`/mnt/storage`) using `mergerfs`.
   * **Creation Policy:** Configured with `category.create=mfs` (most free space) or `epmfs` (existing path, most free space) to balance capacity distribution across physical disks transparently.
   * **Direct I/O & Caching:** Tuned via mount options (`cache.files=partial`, `dropcacheonclose=true`) for optimal streaming throughput with minimal RAM footprint.
3. **Snapshot Parity via `SnapRAID`:**  
   Parity protection is provided by `SnapRAID` using one or two dedicated parity drives (which must be at least as large as the largest data disk).
   * Parity calculations are decoupled from real-time writes.
   * Automated parity synchronization (`snapraid sync`) and sector integrity verification (`snapraid scrub`) run via scheduled systemd timers during low-activity off-peak hours.
   * Notifications and diff thresholds are enforced via a wrapper runner to prevent accidental deletion cascades.
4. **Strict Workload Segregation:**  
   `mergerfs` is strictly reserved for static and bulk media. K3s persistent volumes for database-heavy or I/O-intensive workloads remain pinned to Tier 2 (SSD Mirror) to prevent FUSE locking bottlenecks and uncommitted parity inconsistencies.

## Consequences

**Positive:**
* **Zero-Copy In-Place Onboarding:** Unraid data disks formatted with XFS can be imported into Debian 13 instantly without moving, migrating, or reformatting a single byte.
* **Minimal Blast Radius:** If multiple disks fail simultaneously beyond parity limits (e.g., losing 3 disks with 2 parity drives), only the contents of the failed drives are lost. Surviving disks remain standard XFS volumes with intact data readable on any Linux PC.
* **Asymmetric Drive Expansion:** Drives of arbitrary capacities can be added on-the-fly without rebuilding pools or stranding capacity.
* **Quiet & Localized Read I/O:** Reading a file causes head movement on only the single physical drive containing that file. The remaining drives experience zero I/O contention.
* **Full Wire-Speed Writes:** Writes to the pool hit the underlying disk directly at native SATA/NVMe speeds without the write-penalty of real-time parity calculations.
* **100% Open-Source & GitOps Native:** Fully automated via standard Debian packages (`mergerfs`, `snapraid`), configuration files (`/etc/snapraid.conf`), and Ansible roles.

**Negative / Trade-offs:**
* **Snapshot Parity Window:** Changes made between scheduled `snapraid sync` runs are not protected by parity until the next sync executes. (Mitigated by the static, low-churn WORM nature of bulk media and independent 3-2-1 backups of critical user documents).
* **FUSE Filesystem Overhead:** `mergerfs` runs in userspace, incurring minor CPU/syscall overhead compared to kernel-native VFS. (Negligible on modern multi-core x86_64 CPUs serving gigabit/multi-gigabit network streams).
* **No Real-Time Bitrot Auto-Healing:** Unlike ZFS, bitrot is detected during scheduled `snapraid scrub` runs rather than on every inline read.
* **File Size Constraint:** A single file cannot span across multiple disks; no single file can exceed the free capacity of an individual physical disk.

## Alternatives considered

* **ZFS (RAIDZ1 / RAIDZ2):**  
  Rejected despite enterprise-grade checksumming and snapshot capabilities:
  1. *Mandatory Reformatting:* Creating a zpool requires wiping all disks, making in-place migration of 6.5+ TB of existing Unraid data impossible without purchasing duplicate disks for temporary staging.
  2. *Inflexible Geometry:* Expanding a RAIDZ vdev or mixing disparate drive sizes requires uniform disk replacement or full vdev recreation.
  3. *Synchronized Striping:* Every read request stripes across all pool drives, resulting in simultaneous head seek activity and power draw across every disk.
  4. *Catastrophic Blast Radius:* Losing more disks than the parity fault tolerance destroys the entire pool and all data irrecoverably.
* **Btrfs Native RAID (RAID5 / RAID6):**  
  Rejected because upstream Btrfs parity RAID modes continue to suffer from the well-documented parity write-hole and edge-case corruption risks after unexpected power interruptions. Btrfs RAID1 was rejected due to its 50% capacity overhead for bulk media.
* **Linux Software RAID (`mdadm` RAID 5/6):**  
  Rejected due to mandatory disk formatting, inability to combine mismatched drive sizes, severe write-hole vulnerabilities without dedicated NVMe journals, and all-disk striping overhead.
* **Retaining Unraid OS:**  
  Rejected due to its proprietary licensing model, custom Slackware distribution running out of RAM from a USB stick, and fundamental friction with standard Infrastructure-as-Code (Terraform, Ansible Day-1 provisioning) and K3s cluster architectures.
* **Dedicated Storage Appliances (TrueNAS SCALE / CORE):**  
  Rejected because introducing a separate storage VM with PCIe/HBA passthrough violates our single-node bare-metal architecture, adds unnecessary hypervisor complexity, and inherits the reformatting constraints of ZFS.
* **Distributed / Cloud-Native Storage (Longhorn, Rook-Ceph):**  
  Rejected because distributed block replication engines are designed for multi-node clusters and introduce unacceptable CPU/RAM/IOPS overhead on a single-node homelab machine for multi-terabyte bulk storage.
