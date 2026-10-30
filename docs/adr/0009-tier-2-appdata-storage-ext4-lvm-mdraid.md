# ADR-0009: Tier-2 Appdata Storage via ext4 on LVM on mdraid RAID1

* **Status:** Proposed
* **Date:** 2026-10-27

## Context

Tier 2 holds everything latency-sensitive on the bare-metal node: the K3s runtime (`data-dir`: containerd images, pod overlays, SQLite state), the `local-path-provisioner` PVCs (application databases), and a cache/ingest area for data that is later moved to the Tier-3 bulk pool (ADR-0008).

Constraints:

1. **Start with one NVMe, add the mirror later.** A single 1 TB M.2 NVMe is installed first. A second one will be added later and must become a mirror **without reformatting** and without downtime.
2. **Write load on consumer SSDs.** K3s and database workloads produce many small, `fsync`-heavy writes. The SSDs are consumer models without power-loss protection, so write amplification directly costs lifetime (TBW).
3. **Separate, resizable volumes.** K3s runtime, PVC storage and ingest must be isolated from each other (a full ingest area must not stop K3s), and their sizes must be adjustable later because growth is hard to predict.
4. **In-tree only.** No out-of-tree kernel modules (DKMS), so that unattended kernel security updates stay safe (ADR-0004).
5. **Automatable with Ansible** using standard Debian packages.

This decision is hard to reverse: changing the layout later means backup, reformat and restore of all application data. It must be made before the first bare-metal boot.

## Decision

Tier 2 uses the following stack:

```
NVMe partition ──► mdraid RAID1 (/dev/md0) ──► LVM VG (vg_appdata) ──► LVs ──► ext4
```

1. **mdraid RAID1, created degraded.**
   * The array is created with one real member and one `missing` slot:
     `mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/nvme0n1p1 missing`
   * The second NVMe is added later online with `mdadm --add`. All volumes above `md0` become mirrored at once.
   * Members are partitions, not whole disks, and the partition is sized slightly below the disk capacity, so that a replacement disk with a few MB less capacity still fits.
   * Array definition is persisted in `/etc/mdadm/mdadm.conf` and the initramfs.
2. **LVM on top of `md0`.** One volume group `vg_appdata` with separate logical volumes:
   * `k3s` → `/mnt/appdata/k3s` (K3s `data-dir`)
   * `storage` → `/mnt/appdata/storage` (`default-local-storage-path`)
   * `ingest` → `/mnt/appdata/ingest` (the LV size acts as the quota)
3. **Conservative allocation.** LVs start small. Roughly 30–40 % of the VG stays unallocated as reserve. Growing is done online (`lvextend -r`), shrinking is avoided.
4. **ext4 on each LV.** Mounted with `defaults,nofail`. TRIM via the periodic `fstrim.timer` instead of the `discard` mount option.
5. **Monitoring.** Array state is monitored (`mdadm --monitor` and/or the node-exporter `mdadm` collector, Phase 6), so that a degraded or failed array is noticed.
6. **K3s is bound to every Tier-2 mount.** The K3s unit uses `RequiresMountsFor=` **and** `BindsTo=` on each mount unit it depends on.
   * `RequiresMountsFor=` alone stops K3s only when the mount unit is stopped by a job. If the mount disappears outside systemd (e.g. `umount -l`, device loss), K3s keeps running on a detached filesystem (run 0 and run 1, STO-05), and only the `chattr +i` guard protects the root disk.
   * `BindsTo=` stops K3s whenever the mount unit becomes inactive. A missing volume becomes a loud, complete outage that the node heartbeat (Phase 7) reports, instead of a silent partial failure.
   * This applies already to the single appdata mount of `storage_poc` on the RemoteLab.

## Consequences

**Positive:**
* The mirror can be added later without reformatting or downtime.
* No copy-on-write layer: lower write amplification for small synchronous writes than ZFS or Btrfs.
* Every component (md, device-mapper, ext4) is in-tree and has been in production use for decades. Compatible with unattended kernel updates (ADR-0004).
* Volumes are isolated and can grow online. A full ingest LV does not affect K3s or PVCs.

**Negative & Trade-offs:**
* **No redundancy until the second NVMe is installed.** Until then, a disk failure means restoring from backup (Phase 7).
* **RAID1 is not a backup.** It protects against disk failure, not against deletion, corruption or failed application upgrades. Restic backups (Phase 7) remain mandatory.
* **No data checksums.** Unlike ZFS/Btrfs, silent data corruption is not detected (ext4 only checksums metadata). Mitigated by backups and SMART monitoring.
* **No cheap snapshots.** LVM snapshots exist but are slow for writes. Consistent backups rely on application-level hooks (Phase 7) instead.
* **More layers to automate.** `mdadm` has no dedicated Ansible module (command + templated `mdadm.conf` + `update-initramfs`). LVM is covered by `community.general.lvg` / `lvol`.
* **A short mount interruption takes down the whole cluster** (decision 6). This is intended: losing Tier 2 must not go unnoticed.
* **The storage role and guards must follow the layout.** `storage_poc` (one disk, one mount) does not cover this, and the K3s storage guard (Review 2 R2-1, `RequiresMountsFor`) must cover each mount point K3s depends on.

## Alternatives Considered

* **ZFS mirror:**
  * *Rejected:* Copy-on-write with many small synchronous writes increases SSD wear on consumer NVMe without PLP. Requires out-of-tree DKMS modules, which conflicts with unattended kernel updates (ADR-0004). ARC memory usage competes with workloads on a single node.
* **Btrfs RAID1:**
  * *Rejected:* Also copy-on-write, with the same write-amplification concern. Disabling CoW for database paths (`nodatacow`) also disables checksums, which removes Btrfs' main advantage.
* **ext4 on plain partitions (no LVM):**
  * *Rejected:* Sizes are fixed on day one. Growing a partition requires free space directly behind it, shrinking ext4 requires unmounting. With mdraid, each partition would need its own array.
* **LVM RAID1 (`lvconvert --type raid1`) instead of mdraid:**
  * *Considered:* Uses the same md kernel code and would remove one layer. Rejected in favour of plain `mdadm` because tooling, documentation and monitoring (`mdadm --monitor`, node-exporter collector) are more widespread and the mirror applies to the whole VG at once.
