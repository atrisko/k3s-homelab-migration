# Run 2026-10-30 · remotelab

- **Commit:** `51a0cc4`
- **Environment:** remotelab
- **Starting state:** prepared (Hyper-V checkpoint before the first playbook run)
- **K3s:** `k3s version v1.37.1+k3s1 (356c0254)` · **Argo CD chart:** `10.10.5`
- **OS / Kernel:** `Debian 13.7` / `6.12.111+deb13-amd64`
- **Scope:** full catalog

| ID | Result | Note |
| --- | --- | --- |
| AWS-01 | n/a | remotelab run |
| AWS-02 | n/a | remotelab run |
| AWS-03 | n/a | remotelab run |
| AWS-04 | n/a | remotelab run |
| AWS-05 | n/a | remotelab run |
| IDEM-01 | pass | `ok=57 changed=31 unreachable=0 failed=0 skipped=1`; ifupdown task ran, netplan task skipped (skipped tasks are hidden in the output; `skipped=1` matches) |
| IDEM-02 | pass | `changed=0 failed=0` |
| NET-01 | pass | |
| NET-02 | pass | |
| SYS-01 | pass | |
| SYS-02 | pass | |
| SYS-03 | pass | `Permission denied (publickey)`, exit 255 |
| SYS-04 | pass | `max 1G` |
| SYS-05 | pass | |
| SYS-06 | pass | only `label=Debian-Security`; output also has the empty list header `Origins-Pattern "";` |
| STO-01 | pass | |
| STO-02 | pass | |
| K3S-01 | pass | `v1.37.1+k3s1` |
| K3S-02 | pass | `10.100.34.71 fd85:cc6d:b16f:30::10` |
| K3S-03 | pass | |
| K3S-04 | pass | `argo-cd-10.10.5` |
| GITOPS-03 | pass | |
| REBOOT-01 | pass | reboot issued 13:01:50 CET; boot `-1` ends 13:01:54, boot `0` starts 13:02:07; SSH back at 13:02:18 |
| NET-03 | pass | |
| SYS-07 | pass | |
| SYS-08 | fail | output `2 2 0`: `net.ipv6.conf.eth0.accept_ra` is `0` after reboot; `all` and `default` persist as `2` |
| SYS-09 | fail | exit `1`: all three units `enabled` and `active`, so `NTPSynchronized` was not `yes`; checked about 25 s after boot (13:02:30), no retry |
| STO-03 | pass | `/dev/disk/by-id/scsi-360022480eb62ad2262bbe5f495d502e6 defaults,nofail 2`; mount check `0` |
| K3S-05 | pass | |
| GITOPS-01 | pass | `Synced Healthy` |
| GITOPS-02 | pass | `200` |
| K3S-06 | pass | `10.42.0.31 fd85:cc6d:b16f:4200::1f` |
| IDEM-03 | fail | `changed=1 failed=0`; the only `changed` task is "Set accept_ra at runtime": consequence of SYS-08, not a separate idempotency defect |
| GITOPS-04 | pass | deleted 13:04:09, recreated by 13:04:15 (exit `0`); rollout complete, HTTP `200`; no recovery needed |
| STO-04 | pass | precondition: `Requires=` and `After=` contain `mnt-appdata.mount`; stop job exit `0` (no "target is busy"); `k3s` `inactive`. Recovery: STO-01 `0`, K3S-05 `0`, GITOPS-02 `200` |
| STO-05 | pass | precondition: `findmnt` exit `1`, `lsattr` shows `i`; `sudo touch` → `Operation not permitted`; `ls -A` empty. `k3s` stayed `active` after the lazy unmount. Recovery: no `guard-test` to remove, `sudo mount` ok, `k3s` already active; STO-01 `0`, K3S-05 `0`, GITOPS-02 `200` |
| STO-06 | pass | test: SSH reachable 13:08:28 (no emergency mode); `findmnt` exit `1`; `k3s` `inactive`, journal `Dependency failed for k3s.service` (13:09:30); `lsattr` shows `i`; `sudo touch` → `Operation not permitted`; `is-system-running`: `running` (as in run 0, not a criterion); setup `ls -l "$DISK"` failed as expected. Recovery: STO-01 `0`, K3S-05 `0`, GITOPS-02 `000` at first, `200` on retry (see Deviations) |

## Deviations & Findings

- `SYS-08`: `accept_ra` on the primary interface (`eth0`) does not persist across reboot (`2 2 0`); the runtime setting from the playbook is lost. Confirmed by IDEM-03 reporting `changed` on "Set accept_ra at runtime". → roadmap / issue: TBD
- `SYS-09`: `NTPSynchronized` was not `yes` about 25 s after boot, while the units were enabled and active. Read-only check afterwards (approved by the operator), on a later boot (STO-06 recovery, boot 13:11:48), about 2 min after boot at 13:13:59: `NTPSynchronized=yes`, `System clock synchronized: yes`, server `2.debian.pool.ntp.org`, stratum 2, offset -118 µs, packet count 2. Time sync works; the failure is most likely the test running before the first sync (the command has no wait). Not verified on the boot of SYS-09 itself. → roadmap / issue: TBD
- `STO-06` (recovery): after re-attaching the same VHDX, STO-01 `0` (disk now `sdb` instead of `sda`, the `by-id` path survived) and K3S-05 `0`, but the GITOPS-02 check failed at 13:12:17: rollout reported complete, `curl` printed `000` (exit `7`, no connection to the ClusterIP). A single retry of the GITOPS-02 check at 13:13:01 (44 s later, approved by the operator, no other action in between) printed `200`. Likely a timing gap shortly after boot: `rollout status` reports complete before the service is reachable. Not diagnosed. The test criteria of STO-06 itself were all met. → roadmap / issue: TBD

## Pre-run findings

Defects fixed before this run. They do not show up as failures above.

| Fix commit | Ref | Test ID | Finding | Refuted roadmap item |
| --- | --- | --- | --- | --- |
| `ca50340` | R2-5 | IDEM-01, NET-02 | Network stack detection always failed on ifupdown nodes: `networking.service` is oneshot (`active`/`exited`, not `running`) | Phase 3 · IPv6 under forwarding (R2-4, R2-5) |
| `72cc4af` | R2-1 | STO-05, STO-06 | `chattr +i` was never set on nodes whose appdata volume was already mounted | Phase 3 · Persistent storage (R2-1) |
| `19d455a` | R2-1 | IDEM-02 | `file` with `attributes: +i` reported `changed` on every run (compared against `ie`) | Phase 3 · Reproducible installation (R2-6) |
| `9a5c1a4` | R2-6 | IDEM-02 | Version regex `v\S+` matched "version", causing a reinstall and K3s restart on every run | Phase 3 · Reproducible installation (R2-6) |
